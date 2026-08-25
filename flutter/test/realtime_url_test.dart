import 'package:loomup/loomup.dart';
import 'package:test/test.dart';

void main() {
  test('realtime WebSocket URL preserves the base path', () {
    final cases = {
      'https://tryloomup.com/p/project-id':
          'wss://tryloomup.com/p/project-id/realtime',
      'http://localhost:3000': 'ws://localhost:3000/realtime',
      'https://tryloomup.com/p/project-id/':
          'wss://tryloomup.com/p/project-id/realtime',
    };

    for (final entry in cases.entries) {
      expect(
        realtimeWebSocketUrl(Uri.parse(entry.key)).toString(),
        entry.value,
      );
    }
  });
}
