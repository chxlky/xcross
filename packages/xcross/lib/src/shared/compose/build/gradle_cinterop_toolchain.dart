import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/compose/build/konan_configuration.dart';
import 'package:xcross/src/shared/compose/kotlin_native_class_patches.dart';
import 'package:xcross/src/shared/compose/project/kmp_project.dart';
import 'package:xcross/src/shared/compose/toolchain/compose_toolchain.dart';

@internal
class PreparedGradleCinterop {
  const PreparedGradleCinterop(this.arguments, this.environment);

  final List<String> arguments;
  final Map<String, String> environment;
}

/// Make Gradle's host checks agree with the compiler, without patching its cache.
@internal
class GradleCinteropToolchain<T extends PlatformHostInterface> {
  GradleCinteropToolchain(this.runner);

  final ProcessRunner<T> runner;

  Future<PreparedGradleCinterop?> prepare({
    required KmpProject project,
    required ComposeToolchain<T> toolchain,
  }) async {
    if (toolchain.host.konanTarget != 'linux_x64') return null;
    final prepared = await KonanConfiguration(
      runner,
    ).prepare(project: project, toolchain: toolchain);
    final fs = runner.host.fileSystem;
    final root = fs.directory(
      p.join(p.dirname(prepared.kotlinHome), 'gradle-cinterop-v2'),
    );
    await root.create(recursive: true);
    final home = fs.directory(p.join(root.path, 'kotlin-home'));
    await fs.directory(p.join(home.path, 'konan')).create(recursive: true);

    // cinterop constructs PlatformManager before it reads CLI property overrides.
    for (final entity in fs.directory(toolchain.kotlinHome).listSync()) {
      if (p.basename(entity.path) != 'konan') {
        await _link(entity.path, p.join(home.path, p.basename(entity.path)));
      }
    }
    for (final entity
        in fs.directory(p.join(toolchain.kotlinHome, 'konan')).listSync()) {
      final name = p.basename(entity.path);
      if (name == 'konan.properties') continue;
      final patched = p.join(prepared.kotlinHome, 'konan', name);
      await _link(
        (fs.file(patched).existsSync() || fs.directory(patched).existsSync())
            ? patched
            : entity.path,
        p.join(home.path, 'konan', name),
      );
    }
    await fs
        .file(p.join(home.path, 'konan', 'konan.properties'))
        .writeAsString(
          '${await fs.file(p.join(toolchain.kotlinHome, 'konan', 'konan.properties')).readAsString()}\n'
          '${await fs.file(prepared.konanConfigPath).readAsString()}',
        );

    final agent = fs.file(p.join(root.path, 'host-agent.jar'));
    final source = fs.file(p.join(root.path, 'XcrossHostAgent.java'));
    if (!agent.existsSync() ||
        !source.existsSync() ||
        source.readAsStringSync() != _agentSource) {
      await source.writeAsString(_agentSource);
      final javac = p.join(p.dirname(toolchain.javaExecutable), 'javac');
      await runner.runChecked(javac, [
        '--release',
        '11',
        '-d',
        root.path,
        source.path,
      ]);
      final compiler = ZipDecoder().decodeBytes(
        await fs
            .file(
              p.join(
                prepared.kotlinHome,
                'konan',
                'lib',
                'kotlin-native-compiler-embeddable.jar',
              ),
            )
            .readAsBytes(),
      );
      final archive = Archive();
      void add(String name, List<int> bytes) =>
          archive.addFile(ArchiveFile(name, bytes.length, bytes));
      add(
        'META-INF/MANIFEST.MF',
        'Manifest-Version: 1.0\nPremain-Class: XcrossHostAgent\nCan-Retransform-Classes: true\n\n'
            .codeUnits,
      );
      for (final name in ['HostManager', 'AppleConfigurablesImpl']) {
        final entry = compiler.findFile(
          'org/jetbrains/kotlin/konan/target/$name.class',
        );
        if (entry == null) {
          throw StateError('Missing Kotlin/Native class: $name');
        }
        add('xcross/$name.class', entry.content as List<int>);
      }
      final internalServer = compiler.findFile(
        'org/jetbrains/kotlin/konan/util/InternalServer.class',
      );
      if (internalServer == null) {
        throw StateError('Missing Kotlin/Native InternalServer class');
      }
      add(
        'xcross/InternalServer.class',
        patchInternalServerClassBytes(
          Uint8List.fromList(internalServer.content as List<int>),
        ),
      );
      for (final file in root.listSync().whereType<File>()) {
        if (p.basename(file.path).startsWith('XcrossHostAgent') &&
            p.extension(file.path) == '.class') {
          add(p.basename(file.path), await file.readAsBytes());
        }
      }
      await agent.writeAsBytes(ZipEncoder().encode(archive));
    }
    await fs
        .file(
          p.join(
            project.root,
            'build',
            toolchain.target.outputDirectory,
            'gradle-toolchain.json',
          ),
        )
        .writeAsString(
          '${jsonEncode({'kotlinHome': home.path, 'agent': agent.path, 'konanDataDir': toolchain.konanCache, 'distributionName': p.basename(toolchain.kotlinHome)})}\n',
        );
    final environment = {...prepared.environment};
    environment['JAVA_TOOL_OPTIONS'] = [
      environment['JAVA_TOOL_OPTIONS'],
      '-javaagent:"${agent.path}"',
      '-Dkonan.home="${home.path}"',
    ].whereType<String>().where((value) => value.isNotEmpty).join(' ');
    return PreparedGradleCinterop([
      // Do not contaminate a reusable daemon or cache host-enabled task graphs.
      '--no-daemon', '--no-configuration-cache',
      '-Pkotlin.native.home=${home.path}',
    ], environment);
  }

  Future<void> _link(String source, String destination) async {
    final link = runner.host.fileSystem.link(destination);
    if (link.existsSync()) {
      if (link.targetSync() == source) return;
      await link.delete();
    }
    await link.create(source);
  }
}

const _agentSource = r'''
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.Properties;
import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.ProtectionDomain;
import java.util.HashMap;
import java.util.Map;

public final class XcrossHostAgent {
    // Generate opt-in project-local Gradle settings with Java's properties parser.
    public static void main(String[] args) throws Exception {
        if (args.length != 6) throw new IllegalArgumentException("Expected project, original Gradle home, IDE home, native home, agent, Konan data directory");
        Properties props = new Properties();
        for (Path path : new Path[] {Path.of(args[0], "gradle.properties"), Path.of(args[1], "gradle.properties")}) {
            if (Files.isRegularFile(path)) try (InputStream input = Files.newInputStream(path)) { props.load(input); }
        }
        // Kotlin's native JVM args parser splits on whitespace, without quoting.
        if (args[3].matches(".*\\s.*") || args[4].matches(".*\\s.*")) {
            throw new IllegalArgumentException("IDE native toolchain paths must not contain whitespace");
        }
        String agentArgs = " -javaagent:" + args[4] + " -Dkonan.home=" + args[3];
        props.setProperty("org.gradle.jvmargs", (props.getProperty("org.gradle.jvmargs", "-Xmx2g") + agentArgs).trim());
        props.setProperty("kotlin.native.jvmArgs", (props.getProperty("kotlin.native.jvmArgs", "") + agentArgs).trim());
        props.remove("kotlin.native.home");
        if (!args[5].isEmpty()) props.setProperty("konan.data.dir", args[5]);
        props.setProperty("kotlin.mpp.enableCInteropCommonization", "true");
        props.setProperty("org.gradle.configuration-cache", "false");
        Path directory = Path.of(args[2]);
        Files.createDirectories(directory);
        Files.setPosixFilePermissions(directory, PosixFilePermissions.fromString("rwx------"));
        Path output = directory.resolve("gradle.properties");
        if (!Files.exists(output)) Files.createFile(output, PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")));
        Files.setPosixFilePermissions(output, PosixFilePermissions.fromString("rw-------"));
        try (OutputStream stream = Files.newOutputStream(output)) { props.store(stream, "xcross project-local Gradle configuration; may contain inherited private properties"); }
    }

    public static void premain(String arguments, Instrumentation instrumentation) throws Exception {
        Map<String, byte[]> patches = new HashMap<>();
        for (String name : new String[] {"HostManager", "AppleConfigurablesImpl"}) {
            try (InputStream input = XcrossHostAgent.class.getResourceAsStream("/xcross/" + name + ".class")) {
                if (input == null) throw new IllegalStateException("Missing Kotlin/Native patch: " + name);
                patches.put("org/jetbrains/kotlin/konan/target/" + name, input.readAllBytes());
            }
        }
        try (InputStream input = XcrossHostAgent.class.getResourceAsStream("/xcross/InternalServer.class")) {
            if (input == null) throw new IllegalStateException("Missing Kotlin/Native InternalServer patch");
            patches.put("org/jetbrains/kotlin/konan/util/InternalServer", input.readAllBytes());
        }
        // Run after Gradle's non-retransformable instrumentation transformers.
        instrumentation.addTransformer(new ClassFileTransformer() {
            public byte[] transform(ClassLoader loader, String name, Class<?> type,
                                    ProtectionDomain domain, byte[] original) {
                return patches.get(name);
            }
        }, true);
    }
}
''';
