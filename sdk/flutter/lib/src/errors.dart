/// Error thrown by the Litebase client for HTTP and protocol failures.
class LitebaseException implements Exception {
  final String message;
  final String? code;
  final int? status;

  const LitebaseException(this.message, {this.code, this.status});

  @override
  String toString() {
    final parts = <String>['LitebaseException: $message'];
    if (code != null) parts.add('code=$code');
    if (status != null) parts.add('status=$status');
    return parts.join(' ');
  }
}
