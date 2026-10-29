import 'download_stub.dart' if (dart.library.js_interop) 'download_web.dart' as impl;

/// Saves [content] as a file in the browser. Returns false where downloads
/// are not available (tests), in which case nothing happens.
Future<bool> downloadTextFile(String fileName, String content, {String mimeType = 'text/csv'}) =>
    impl.download(fileName, content, mimeType);
