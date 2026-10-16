import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:http_parser/http_parser.dart';

import 'models.dart';

class ChatApi {
  ChatApi({Dio? dio, String? baseUrl})
    : dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl:
                  baseUrl ??
                  const String.fromEnvironment(
                    'API_BASE_URL',
                    defaultValue: 'http://localhost:3000',
                  ),
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 20),
            ),
          );
  final Dio dio;
  int messageRequests = 0;
  void setToken(String? token) {
    if (token == null) {
      dio.options.headers.remove('Authorization');
    } else {
      dio.options.headers['Authorization'] = 'Bearer $token';
    }
  }

  Future<Object?> request(
    String method,
    String path, {
    Map<String, dynamic>? data,
    Map<String, dynamic>? query,
  }) async {
    try {
      return (await dio.request<Object?>(
        path,
        data: data,
        queryParameters: query,
        options: Options(method: method),
      )).data;
    } on DioException catch (error) {
      final body = error.response?.data;
      if (body is Map) {
        final message = body['detail'] ?? body['message'];
        if (message != null) {
          throw ChatApiException(
            message is List ? message.join(', ') : message.toString(),
            statusCode: error.response?.statusCode,
          );
        }
      }
      throw ChatApiException(
        error.type == DioExceptionType.connectionError
            ? 'Cannot reach the chat server. Please try again.'
            : error.message ?? 'Request failed.',
        statusCode: error.response?.statusCode,
      );
    }
  }

  Future<Map<String, dynamic>> getMap(
    String path, {
    Map<String, dynamic>? query,
  }) async => jsonMap(await request('GET', path, query: query));
  Future<Map<String, dynamic>> post(
    String path, [
    Map<String, dynamic>? body,
  ]) async => jsonMap(await request('POST', path, data: body));
  Future<List<UserProfile>> getUsers(String path) async =>
      ((await request('GET', path)) as List)
          .map((u) => UserProfile.fromJson(jsonMap(u)))
          .toList();
  Future<Map<String, dynamic>> latestMessages(
    String roomId, {
    ChatMessage? before,
  }) {
    messageRequests++;
    return getMap(
      '/rooms/$roomId/messages',
      query: {
        'limit': 30,
        if (before != null)
          'beforeCreatedAt': before.createdAt.toIso8601String(),
        if (before != null) 'beforeId': before.id,
      },
    );
  }

  Future<String> uploadImage(Uint8List bytes, String filename) async {
    if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024) {
      throw const ChatApiException('Choose an image smaller than 5 MB.');
    }
    final extension = filename.split('.').last.toLowerCase();
    final mime = switch (extension) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      _ => null,
    };
    if (mime == null) {
      throw const ChatApiException('Choose a JPEG, PNG, WebP, or GIF image.');
    }
    try {
      final response = await dio.post<Object?>(
        '/uploads/image',
        data: FormData.fromMap({
          'file': MultipartFile.fromBytes(
            bytes,
            filename: filename,
            contentType: MediaType.parse(mime),
          ),
        }),
      );
      final body = jsonMap(response.data);
      return (body['imageUrl'] ?? body['url']) as String;
    } on DioException catch (error) {
      throw ChatApiException(
        error.response?.data is Map
            ? (error.response!.data['message'] ?? 'Image upload failed.')
                  .toString()
            : 'Image upload failed.',
      );
    }
  }

  String absoluteImageUrl(String path) =>
      Uri.parse(dio.options.baseUrl).resolve(path).toString();
}

class ChatApiException implements Exception {
  const ChatApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}
