# KeyboardShortcuts 2.3.0

Source: https://github.com/sindresorhus/KeyboardShortcuts/tree/2.3.0

This directory contains the upstream Swift package sources and tests, under their
original MIT license. The sole source adaptation is `String.localized` in
`Sources/KeyboardShortcuts/Utilities.swift`: try the application Resources directory
before the generated SwiftPM `Bundle.module` fallback. This makes the library work
in a standalone signed `.app` without placing unsealed resources in the bundle root.

Global shortcut registration and the native recorder are upstream implementations.
Review and retain this resource adaptation when updating the vendored version.
