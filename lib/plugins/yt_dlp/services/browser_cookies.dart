class BrowserCookies {
  static const browsers = {
    'files': '手动导入的 Cookie',
    'firefox': 'Firefox',
    'edge': 'Microsoft Edge',
    'chrome': 'Google Chrome',
    'brave': 'Brave',
    'chromium': 'Chromium',
    'opera': 'Opera',
    'vivaldi': 'Vivaldi',
    'safari': 'Safari（macOS）'
  };
  static String? failureHelp(String output, Map<String, String> options,
      {int? failureKind}) {
    final text = output.toLowerCase();
    final browser = browsers[options['cookie-browser']] ?? '所选浏览器';
    if (failureKind == 1 ||
        text.contains('could not copy chrome cookie database')) {
      return '无法读取 $browser 的 Cookie 数据库，通常是浏览器仍在运行或文件访问受限。'
          '\n请先保存网页中的工作，完全退出浏览器；检查任务管理器中是否仍有浏览器后台进程，再重试。'
          '\nEdge 可在设置中关闭“启动增强”和“关闭后继续运行后台扩展和应用”，再退出。'
          '\n如果仍失败，请在 Firefox 登录同一网站后切换 Cookie 来源，或导入 cookies.txt 并选择“手动导入的 Cookie”。'
          '\n这一步尚未读取到登录状态，调整画质或 Aria2 参数无法解决。';
    }
    if (failureKind == 2 ||
        text.contains('failed to decrypt') ||
        text.contains('could not decrypt') ||
        text.contains('app-bound encryption')) {
      return '$browser 的 Cookie 解密失败。关闭浏览器不一定能解决加密兼容问题。'
          '\n请更新 yt-dlp 后重试；也可在 Firefox 登录同一网站后切换 Cookie 来源，或手动导入 cookies.txt。'
          '\n使用导入文件时，必须将 Cookie 来源改为“手动导入的 Cookie”并应用。';
    }
    return null;
  }

  static bool enabled(Map<String, String> options) =>
      (options['cookie-browser'] ?? 'files') != 'files';
  static List<String> arguments(Map<String, String> options) {
    final browser = options['cookie-browser'] ?? 'files';
    if (!browsers.containsKey(browser)) {
      throw const FormatException('不支持的 Cookie 浏览器');
    }
    if (browser == 'files') return [];
    final profile = (options['cookie-profile'] ?? '').trim();
    if (profile.contains('\n') || profile.contains('\r')) {
      throw const FormatException('浏览器配置不能包含换行');
    }
    return [
      '--cookies-from-browser',
      profile.isEmpty ? browser : '$browser:$profile'
    ];
  }
}
