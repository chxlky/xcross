@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

import platform.UIKit.UIViewController
import probe.xcrossInteropMessage

fun MainViewController() = UIViewController().apply {
    title = xcrossInteropMessage()
}
