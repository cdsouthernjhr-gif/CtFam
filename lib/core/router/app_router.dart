import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../features/authentication/presentation/auth_screens.dart';
import '../../features/authentication/presentation/verify_code_screen.dart';
import '../../features/calendar/presentation/calendar_screen.dart';
import '../../features/calendar/presentation/event_detail_screen.dart';
import '../../features/calendar/presentation/event_form_screen.dart';
import '../../features/chat/presentation/chat_screen.dart';
import '../../features/chat/presentation/conversation_screen.dart';
import '../../features/chat/presentation/group_info_screen.dart';
import '../../features/dashboard/presentation/dashboard_screen.dart';
import '../../features/dashboard/presentation/home_shell.dart';
import '../../features/family/presentation/activity_screen.dart';
import '../../features/family/presentation/create_family_screen.dart';
import '../../features/family/presentation/family_screen.dart';
import '../../features/family/presentation/family_settings_screen.dart';
import '../../features/family/presentation/onboarding_screen.dart';
import '../../features/invitation/presentation/create_invitation_screen.dart';
import '../../features/notifications/presentation/notification_settings_screen.dart';
import '../../features/notifications/presentation/notifications_screen.dart';
import '../../features/invitation/presentation/invitations_screen.dart';
import '../../features/invitation/presentation/join_family_screen.dart';
import '../../features/settings/presentation/profile_screen.dart';
import '../../features/todo/presentation/todo_activity_screen.dart';
import '../../features/todo/presentation/todo_list_screen.dart';
import '../../features/todo/presentation/todo_screen.dart';
import '../../shared/providers/session_controller.dart';
import '../utils/invite_code.dart';
import 'routes.dart';
import 'system_screens.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();

/// Pure redirect logic, unit tested in test/unit/router_redirect_test.dart.
String? resolveRedirect(SessionState session, Uri uri) {
  final path = uri.path;
  switch (session.status) {
    case SessionStatus.unconfigured:
      return path == Routes.configError ? null : Routes.configError;
    case SessionStatus.initializing:
      return path == Routes.splash ? null : Routes.splash;
    case SessionStatus.error:
      return path == Routes.sessionError ? null : Routes.sessionError;
    case SessionStatus.passwordRecovery:
      return path == Routes.resetPassword ? null : Routes.resetPassword;
    case SessionStatus.signedOut:
      if (Routes.publicRoutes.contains(path)) return null;
      return Routes.signIn;
    case SessionStatus.needsFamily:
      if (session.pendingInviteCode != null && path != Routes.join) {
        return Routes.joinWithCode(session.pendingInviteCode!);
      }
      if (Routes.noFamilyRoutes.contains(path)) return null;
      return Routes.onboarding;
    case SessionStatus.ready:
      if (session.pendingInviteCode != null && path != Routes.join) {
        return Routes.joinWithCode(session.pendingInviteCode!);
      }
      const entryRoutes = {
        Routes.splash,
        Routes.configError,
        Routes.sessionError,
        Routes.resetPassword,
        Routes.onboarding,
        Routes.signIn,
        Routes.signUp,
        Routes.forgotPassword,
        '/',
      };
      if (entryRoutes.contains(path)) return Routes.home;
      return null;
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref.listen(sessionControllerProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  final router = GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: Routes.splash,
    refreshListenable: refresh,
    redirect: (context, state) {
      final session = ref.read(sessionControllerProvider);
      // Remember invitation deep links opened while signed out.
      if (state.uri.path == Routes.join && session.status == SessionStatus.signedOut) {
        final code = InviteCode.extract(state.uri.toString());
        if (code != null) {
          Future.microtask(() => ref.read(sessionControllerProvider.notifier).setPendingInvite(code));
        }
      }
      return resolveRedirect(session, state.uri);
    },
    routes: [
      GoRoute(path: '/', redirect: (_, _) => Routes.splash),
      GoRoute(path: Routes.splash, builder: (_, _) => const SplashScreen()),
      GoRoute(path: Routes.configError, builder: (_, _) => const ConfigErrorScreen()),
      GoRoute(path: Routes.sessionError, builder: (_, _) => const SessionErrorScreen()),
      GoRoute(path: Routes.signIn, builder: (_, _) => const SignInScreen()),
      GoRoute(path: Routes.signUp, builder: (_, _) => const SignUpScreen()),
      GoRoute(path: Routes.forgotPassword, builder: (_, _) => const ForgotPasswordScreen()),
      GoRoute(path: Routes.resetPassword, builder: (_, _) => const ResetPasswordScreen()),
      GoRoute(
        path: Routes.verifyCode,
        builder: (_, state) => VerifyCodeScreen(
          email: state.uri.queryParameters['email'] ?? '',
          recovery: state.uri.queryParameters['purpose'] == 'recovery',
        ),
      ),
      GoRoute(path: Routes.onboarding, builder: (_, _) => const OnboardingScreen()),
      GoRoute(path: Routes.createFamily, builder: (_, _) => const CreateFamilyScreen()),
      GoRoute(
        path: Routes.join,
        builder: (_, state) => JoinFamilyScreen(initialCode: state.uri.queryParameters['code']),
      ),
      GoRoute(
        path: Routes.profile,
        builder: (_, _) => const ProfileScreen(),
        routes: [
          GoRoute(path: 'password', builder: (_, _) => const ResetPasswordScreen()),
          GoRoute(path: 'notifications', builder: (_, _) => const NotificationSettingsScreen()),
        ],
      ),
      GoRoute(path: Routes.familySettings, builder: (_, _) => const FamilySettingsScreen()),
      GoRoute(path: Routes.invite, builder: (_, _) => const CreateInvitationScreen()),
      GoRoute(path: Routes.invitations, builder: (_, _) => const InvitationsScreen()),
      GoRoute(path: Routes.activity, builder: (_, _) => const ActivityScreen()),
      GoRoute(path: Routes.notifications, builder: (_, _) => const NotificationsScreen()),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => HomeShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [GoRoute(path: Routes.home, builder: (_, _) => const DashboardScreen())],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.chat,
                builder: (_, _) => const ChatScreen(),
                routes: [
                  GoRoute(
                    path: ':conversationId',
                    builder: (_, state) => ConversationScreen(conversationId: state.pathParameters['conversationId']!),
                    routes: [
                      GoRoute(
                        path: 'info',
                        builder: (_, state) => GroupInfoScreen(conversationId: state.pathParameters['conversationId']!),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.todo,
                builder: (_, _) => const TodoScreen(),
                routes: [
                  GoRoute(
                    path: ':listId',
                    builder: (_, state) => TodoListScreen(listId: state.pathParameters['listId']!),
                    routes: [
                      GoRoute(
                        path: 'activity',
                        builder: (_, state) => TodoActivityScreen(listId: state.pathParameters['listId']!),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.calendar,
                builder: (_, _) => const CalendarScreen(),
                routes: [
                  GoRoute(
                    path: 'new',
                    parentNavigatorKey: rootNavigatorKey,
                    builder: (_, state) =>
                        EventFormScreen(initialDate: DateTime.tryParse(state.uri.queryParameters['date'] ?? '')),
                  ),
                  GoRoute(
                    path: ':eventId',
                    builder: (_, state) => EventDetailScreen(
                      eventId: state.pathParameters['eventId']!,
                      occurrenceStart: DateTime.tryParse(state.uri.queryParameters['at'] ?? '')?.toLocal(),
                    ),
                    routes: [
                      GoRoute(
                        path: 'edit',
                        parentNavigatorKey: rootNavigatorKey,
                        builder: (_, state) => EventFormScreen(eventId: state.pathParameters['eventId']),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: Routes.family, builder: (_, _) => const FamilyScreen())],
          ),
        ],
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
