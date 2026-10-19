import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/exports.dart';
import 'theme.dart';

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});
  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _username = TextEditingController();
  final _name = TextEditingController();
  bool _signup = false;
  bool _obscure = true;
  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _username.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    final controller = ref.read(chatControllerProvider);
    if (_signup) {
      await controller.signup(
        _username.text.trim(),
        _email.text.trim(),
        _password.text,
        _name.text.trim(),
      );
    } else {
      await controller.login(_email.text.trim(), _password.text);
    }
    if (mounted &&
        controller.currentUser != null &&
        !controller.requiresReauthentication &&
        Navigator.canPop(context)) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(chatControllerProvider);
    c.debugInspector.recordBuild(
      'AuthScreen',
      context: c.lastStateContext,
      notificationId: c.lastStateNotificationId,
    );
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth > 1000;
            final form = Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(28),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 470),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          BrandMark(),
                          SizedBox(width: 12),
                          Text(
                            'Chat Workspace',
                            style: TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 36),
                      Text(
                        _signup
                            ? 'Make yourself at home.'
                            : 'Good conversations\nstart here.',
                        style: const TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -1.2,
                          height: 1.14,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _signup
                            ? 'Create your account and bring everyone together.'
                            : 'Sign in to your space. Your messages will be right here.',
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.5,
                          color: ChatColors.of(context).muted,
                        ),
                      ),
                      const SizedBox(height: 28),
                      if (c.error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 20),
                          child: _AuthError(
                            message: c.error!,
                            onDismiss: c.clearError,
                          ),
                        ),
                      Form(
                        key: _form,
                        child: Column(
                          children: [
                            if (_signup) ...[
                              TextFormField(
                                key: const Key('signup-name'),
                                controller: _name,
                                decoration: const InputDecoration(
                                  labelText: 'Display name',
                                  prefixIcon: Icon(Icons.person_outline),
                                ),
                                validator: (s) => s == null || s.trim().isEmpty
                                    ? 'Enter your name'
                                    : null,
                              ),
                              const SizedBox(height: 14),
                              TextFormField(
                                key: const Key('signup-username'),
                                controller: _username,
                                decoration: const InputDecoration(
                                  labelText: 'Username',
                                  prefixIcon: Icon(Icons.alternate_email),
                                ),
                                validator: (s) =>
                                    s == null || s.trim().length < 3
                                    ? 'Use at least 3 characters'
                                    : null,
                              ),
                              const SizedBox(height: 14),
                            ],
                            TextFormField(
                              key: const Key('auth-email'),
                              controller: _email,
                              keyboardType: TextInputType.emailAddress,
                              autofillHints: const [AutofillHints.email],
                              decoration: const InputDecoration(
                                labelText: 'Email address',
                                prefixIcon: Icon(Icons.mail_outline),
                              ),
                              validator: (s) => s == null || !s.contains('@')
                                  ? 'Enter a valid email address'
                                  : null,
                            ),
                            const SizedBox(height: 14),
                            TextFormField(
                              key: const Key('auth-password'),
                              controller: _password,
                              obscureText: _obscure,
                              autofillHints: [
                                if (_signup)
                                  AutofillHints.newPassword
                                else
                                  AutofillHints.password,
                              ],
                              onFieldSubmitted: (_) =>
                                  c.busy ? null : _submit(),
                              decoration: InputDecoration(
                                labelText: 'Password',
                                prefixIcon: const Icon(Icons.lock_outline),
                                suffixIcon: IconButton(
                                  tooltip: _obscure
                                      ? 'Show password'
                                      : 'Hide password',
                                  icon: Icon(
                                    _obscure
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                  ),
                                  onPressed: () =>
                                      setState(() => _obscure = !_obscure),
                                ),
                              ),
                              validator: (s) => s == null || s.length < 8
                                  ? 'Use at least 8 characters'
                                  : null,
                            ),
                            const SizedBox(height: 20),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton(
                                key: const Key('auth-submit'),
                                onPressed: c.busy ? null : _submit,
                                child: c.busy
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : Text(
                                        _signup ? 'Create account' : 'Sign in',
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            _signup
                                ? 'Already have an account?'
                                : 'New around here?',
                            style: TextStyle(
                              color: ChatColors.of(context).muted,
                            ),
                          ),
                          TextButton(
                            onPressed: c.busy
                                ? null
                                : () => setState(() {
                                    _signup = !_signup;
                                    _form.currentState?.reset();
                                    c.clearError();
                                  }),
                            child: Text(_signup ? 'Sign in' : 'Create account'),
                          ),
                        ],
                      ),
                      if (c.demoEnabled) ...[
                        const SizedBox(height: 22),
                        Row(
                          children: [
                            Expanded(child: Divider()),
                            Padding(
                              padding: EdgeInsets.symmetric(horizontal: 12),
                              child: Text(
                                'OR EXPLORE THE DEMO',
                                style: TextStyle(
                                  fontSize: 10,
                                  letterSpacing: 1.4,
                                  color: ChatColors.of(context).muted,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Expanded(child: Divider()),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: List.generate(
                            5,
                            (index) => SizedBox(
                              width: 76,
                              child: OutlinedButton(
                                key: Key('debug-user-${index + 1}'),
                                onPressed: c.busy
                                    ? null
                                    : () async {
                                        await c.debugLogin(index + 1);
                                        if (context.mounted &&
                                            c.currentUser != null &&
                                            !c.requiresReauthentication &&
                                            Navigator.canPop(context)) {
                                          Navigator.pop(context);
                                        }
                                      },
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  side: BorderSide(
                                    color: ChatColors.of(context).border,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: Column(
                                  children: [
                                    ChatAvatar(
                                      name: 'User ${index + 1}',
                                      id: '${index + 1}',
                                      radius: 18,
                                    ),
                                    const SizedBox(height: 9),
                                    Text(
                                      'User ${index + 1}',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'Five local demo accounts, ready for a conversation.',
                          style: TextStyle(
                            fontSize: 12,
                            color: ChatColors.of(context).muted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
            if (!wide) return form;
            return Row(
              children: [
                Expanded(
                  child: Container(
                    color: ChatColors.of(context).welcome,
                    child: const _WelcomeArt(),
                  ),
                ),
                Expanded(child: form),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _AuthError extends StatelessWidget {
  const _AuthError({required this.message, required this.onDismiss});
  final String message;
  final VoidCallback onDismiss;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: Colors.redAccent, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: const TextStyle(fontSize: 13))),
          IconButton(
            tooltip: 'Dismiss error',
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    ),
  );
}

class _WelcomeArt extends StatelessWidget {
  const _WelcomeArt();
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(48),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 430),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const BrandMark(large: true),
            const SizedBox(height: 40),
            Text(
              'A little closer.\nOne message\nat a time.',
              style: TextStyle(
                fontSize: 51,
                height: 1.08,
                letterSpacing: -2,
                fontWeight: FontWeight.w700,
                color: ChatColors.of(context).ink,
              ),
            ),
            const SizedBox(height: 28),
            Text(
              'A calm space for the people, projects, and conversations that matter.',
              style: TextStyle(
                fontSize: 17,
                height: 1.6,
                color: ChatColors.of(context).muted,
              ),
            ),
            const SizedBox(height: 48),
            _artBubble(context, 'Hey, are we still on for tomorrow?', false),
            const SizedBox(height: 12),
            _artBubble(context, 'Of course. Looking forward to it!', true),
            const SizedBox(height: 36),
            Row(
              children: [
                Icon(Icons.bolt_outlined, size: 18, color: ChatColors.primary),
                SizedBox(width: 8),
                Text(
                  'Instant updates. Always in sync.',
                  style: TextStyle(
                    color: ChatColors.of(context).muted,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  Widget _artBubble(BuildContext context, String text, bool mine) => Align(
    alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: mine ? ChatColors.primary : ChatColors.of(context).surface,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: mine ? Colors.white : ChatColors.of(context).ink,
          fontSize: 14,
        ),
      ),
    ),
  );
}
