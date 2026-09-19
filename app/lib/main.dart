import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/audit/audit_screen.dart';
import 'src/theme.dart';

void main() {
  runApp(const ProviderScope(child: ColdwaterApp()));
}

class ColdwaterApp extends StatelessWidget {
  const ColdwaterApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Coldwater',
        debugShowCheckedModeBanner: false,
        theme: ColdwaterTheme.light(),
        darkTheme: ColdwaterTheme.dark(),
        home: const AuditScreen(),
      );
}
