import 'package:audit_core/audit_core.dart';
import 'package:coldwater/src/audit/audit_controller.dart';
import 'package:coldwater/src/audit/widgets/cut_list.dart';
import 'package:coldwater/src/audit/widgets/reality_check_card.dart';
import 'package:coldwater/src/audit/widgets/spending_breakdown_bar.dart';
import 'package:coldwater/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _json() => <String, dynamic>{
      'currency': 'GBP',
      'period_start': '2026-03-01',
      'period_end': '2026-03-31',
      'total_net_income': 3000.00,
      'total_expenses': 2000.00,
      'needs': <Map<String, dynamic>>[
        {
          'label': 'Rent',
          'amount': 1350.00,
          'category': 'housing',
          'evidence': <String, dynamic>{'quote': 'RENT 1350.00', 'date': null},
        },
      ],
      'wants': <Map<String, dynamic>>[
        {
          'label': 'Deliveroo',
          'amount': 240.00,
          'category': 'delivery',
          'evidence': <String, dynamic>{'quote': 'DELIVEROO', 'date': null},
        },
        {
          'label': 'Tesco',
          'amount': 410.00,
          'category': 'groceries',
          'evidence': <String, dynamic>{'quote': 'TESCO', 'date': null},
        },
      ],
      'wasteful_leaks': <Map<String, dynamic>>[
        {
          'label': 'Deliveroo',
          'amount': 240.00,
          'monthly_equivalent': 240.00,
          'severity': 'severe',
          'verdict': 'That is 2880.00 a year to avoid walking to a kitchen.',
          'evidence': <String, dynamic>{'quote': 'DELIVEROO', 'date': null},
        },
      ],
      'harsh_audit_summary': 'You kept 1000.00 of 3000.00.',
      'action_plan': <String>['Cancel Deliveroo.', 'Move the surplus.'],
    };

AuditReady _ready({
  Set<String> dismissed = const {},
  void Function(Map<String, dynamic>)? mutate,
}) {
  final json = _json();
  mutate?.call(json);
  final report = AuditReport.fromJson(json);
  return AuditReady(
    AuditOutcome(
      report: report,
      raw: json,
      arithmetic: verifyArithmetic(report),
      route: IngestionRoute.attachment,
      routeReason: 'Sent as a PDF.',
      evidenceChecked: true,
    ),
    dismissed: dismissed,
  );
}

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(
        theme: ColdwaterTheme.light(),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

void main() {
  group('RealityCheckCard', () {
    testWidgets('names a surplus in words, not only in colour',
        (tester) async {
      await _pump(tester, RealityCheckCard(state: _ready()));

      expect(find.text('Surplus'), findsOneWidget);
      expect(find.textContaining('1,000.00'), findsOneWidget);
      expect(find.text('You kept 1000.00 of 3000.00.'), findsOneWidget);
    });

    testWidgets('names a deficit when spending outran income', (tester) async {
      await _pump(
        tester,
        RealityCheckCard(
          state: _ready(mutate: (j) => j['total_net_income'] = 1500.0),
        ),
      );

      expect(find.text('Deficit'), findsOneWidget);
      expect(find.textContaining('-£500.00'), findsOneWidget);
    });

    testWidgets('reports what has been cut so far', (tester) async {
      await _pump(
        tester,
        RealityCheckCard(state: _ready(dismissed: {'Deliveroo'})),
      );

      expect(find.textContaining('Cut so far'), findsOneWidget);
      expect(find.textContaining('2,880.00'), findsOneWidget);
    });
  });

  group('TrustBanner', () {
    testWidgets('stays out of the way when the audit reconciles',
        (tester) async {
      await _pump(tester, TrustBanner(outcome: _ready().outcome));
      expect(find.byType(ExpansionTile), findsNothing);
    });

    testWidgets('speaks up when the totals do not add up', (tester) async {
      final state = _ready(mutate: (j) => j['total_expenses'] = 1200.0);
      await _pump(tester, TrustBanner(outcome: state.outcome));

      expect(
        find.textContaining("arithmetic does not add up"),
        findsOneWidget,
      );
    });
  });

  group('SpendingBreakdownBar', () {
    testWidgets('labels every segment rather than relying on colour',
        (tester) async {
      await _pump(tester, SpendingBreakdownBar(report: _ready().report));

      expect(find.text('Needs'), findsOneWidget);
      expect(find.text('Wants'), findsOneWidget);
      expect(find.text('Wasteful'), findsOneWidget);

      // Needs 1350, wants 410 after carving out the 240 leak, leaks 240.
      expect(find.text('68%'), findsOneWidget);
      expect(find.text('21%'), findsOneWidget);
      expect(find.text('12%'), findsOneWidget);
    });

    testWidgets('says so when there is no spending to draw', (tester) async {
      await _pump(
        tester,
        SpendingBreakdownBar(
          report: _ready(mutate: (j) {
            j['needs'] = <Map<String, dynamic>>[];
            j['wants'] = <Map<String, dynamic>>[];
            j['wasteful_leaks'] = <Map<String, dynamic>>[];
          }).report,
        ),
      );

      expect(find.textContaining('No spending was found'), findsOneWidget);
    });
  });

  group('LeakCard', () {
    testWidgets('shows the severity and the blunt verdict', (tester) async {
      await _pump(
        tester,
        LeakCard(
          leak: _ready().report.wastefulLeaks.single,
          currency: 'GBP',
          unverified: false,
          onDismissed: () {},
        ),
      );

      expect(find.text('Deliveroo'), findsOneWidget);
      expect(find.text('severe'), findsOneWidget);
      expect(find.textContaining('avoid walking to a kitchen'), findsOneWidget);
      expect(find.textContaining('2,880.00'), findsOneWidget);
    });

    testWidgets('marks a leak whose transaction could not be found',
        (tester) async {
      await _pump(
        tester,
        LeakCard(
          leak: _ready().report.wastefulLeaks.single,
          currency: 'GBP',
          unverified: true,
          onDismissed: () {},
        ),
      );

      expect(
        find.textContaining('Could not find this transaction'),
        findsOneWidget,
      );
    });

    testWidgets('swiping commits the cut', (tester) async {
      var dismissed = false;
      await _pump(
        tester,
        LeakCard(
          leak: _ready().report.wastefulLeaks.single,
          currency: 'GBP',
          unverified: false,
          onDismissed: () => dismissed = true,
        ),
      );

      await tester.drag(find.byType(Dismissible), const Offset(600, 0));
      await tester.pumpAndSettle();

      expect(dismissed, isTrue);
    });
  });

  testWidgets('ActionPlanCard numbers the steps', (tester) async {
    await _pump(tester, const ActionPlanCard(steps: ['First', 'Second']));

    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('First'), findsOneWidget);
  });

  testWidgets('ActionPlanCard disappears when there is no plan',
      (tester) async {
    await _pump(tester, const ActionPlanCard(steps: []));
    expect(find.byType(Card), findsNothing);
  });
}
