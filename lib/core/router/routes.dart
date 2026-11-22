abstract final class Routes {
  static const splash = '/splash';
  static const configError = '/config-error';
  static const sessionError = '/session-error';
  static const signIn = '/sign-in';
  static const signUp = '/sign-up';
  static const forgotPassword = '/forgot-password';
  static const resetPassword = '/reset-password';
  static const onboarding = '/onboarding';
  static const createFamily = '/create-family';
  static const join = '/join';
  static const profile = '/profile';
  static const changePassword = '/profile/password';

  // Bottom navigation branches
  static const home = '/home';
  static const chat = '/chat';
  static const todo = '/todo';
  static const calendar = '/calendar';
  static const family = '/family';

  // Family sub-pages (pushed over the shell)
  static const familySettings = '/family-settings';
  static const invite = '/invite';
  static const invitations = '/invitations';
  static const activity = '/activity';

  static const publicRoutes = {signIn, signUp, forgotPassword};
  static const noFamilyRoutes = {onboarding, createFamily, join, profile, changePassword};

  static String joinWithCode(String code) => Uri(path: join, queryParameters: {'code': code}).toString();
}
