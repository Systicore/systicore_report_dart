import 'dart:io';

/// Whether [cause], the error behind a `DioExceptionType.unknown`, is a
/// failure of the connection itself.
///
/// dio's IO adapter maps only a SocketException raised while opening the
/// connection to `connectionError`. A socket that fails later ("Connection
/// reset by peer"), an HttpException ("Connection closed before full
/// header was received" before dio 5.10) and a failed TLS handshake arrive
/// as `unknown`, with the exception as the cause. Other IOExceptions, such
/// as a FileSystemException from a download, are not network failures.
///
/// A RedirectException ("Redirect limit exceeded", "Redirect loop
/// detected") is an HttpException too, but it comes from the server's or
/// the client's redirect setup, not from a broken connection.
bool isNetworkFailureCause(Object? cause) =>
    cause is SocketException ||
    (cause is HttpException && cause is! RedirectException) ||
    cause is TlsException;
