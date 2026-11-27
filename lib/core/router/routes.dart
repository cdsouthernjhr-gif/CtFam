abstract final class Routes {
  static const splash = '/splash';
  static const configError = '/config-error';
  static const sessionError = '/session-error';
  static const signIn = '/sign-in';
  static const signUp = '/sign-up';
  static const forgotPassword = '/forgot-password';
  static const resetPassword = '/reset-password';
  static const verifyCode = '/verify-code';
  static const onboarding = '/onboarding';
  static const createFamily = '/create-family';
  static const join = '/join';
  static const profile = '/profile';
  static const changePassword = '/profile/password';
  static const notificationSettings = '/profile/notifications';
  static const about = '/profile/about';
  static const notifications = '/notifications';
  static const sync = '/sync';
  static const familyTree = '/family-tree';
  static const familyLinks = '/family-links';
  static String treePerson(String id) => '$familyTree/$id';
  static const collections = '/collections';
  static String collection(String id) => '$collections/$id';

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

  static const publicRoutes = {signIn, signUp, forgotPassword, verifyCode};
  static const noFamilyRoutes = {
    onboarding,
    createFamily,
    join,
    profile,
    changePassword,
    notificationSettings,
    about,
    sync,
  };

  static String verifyCodeFor(String email, {required bool recovery}) =>
      Uri(path: verifyCode, queryParameters: {'email': email, 'purpose': recovery ? 'recovery' : 'signup'}).toString();

  static String newEventOn(DateTime day) => Uri(
    path: '$calendar/new',
    queryParameters: {
      'date':
          '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}',
    },
  ).toString();

  static String eventDetail(String id, {DateTime? occurrence}) => Uri(
    path: '$calendar/$id',
    queryParameters: occurrence == null ? null : {'at': occurrence.toUtc().toIso8601String()},
  ).toString();

  static String eventEdit(String id) => '$calendar/$id/edit';

  static String joinWithCode(String code) => Uri(path: join, queryParameters: {'code': code}).toString();
}
