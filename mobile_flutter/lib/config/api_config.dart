class ApiConfig {
  static const String baseUrl = String.fromEnvironment(
    "API_BASE_URL",
    defaultValue: "http://10.152.173.28:8000",
  );
}
