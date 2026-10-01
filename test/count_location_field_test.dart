import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/widgets/count_location_field.dart';

void main() {
  Widget page(
    List<String?> locations,
    String? selected, {
    ValueChanged<String?>? changed,
    bool readOnly = false,
  }) => MaterialApp(
    home: Scaffold(
      body: CountLocationField(
        locations: locations,
        value: selected,
        readOnly: readOnly,
        onChanged: changed ?? (_) {},
      ),
    ),
  );
  DropdownButtonFormField<String> field(WidgetTester tester) =>
      tester.widget<DropdownButtonFormField<String>>(
        find.byType(DropdownButtonFormField<String>),
      );
  DropdownButton<String> dropdown(WidgetTester tester) =>
      tester.widget<DropdownButton<String>>(
        find.descendant(
          of: find.byType(DropdownButtonFormField<String>),
          matching: find.byType(DropdownButton<String>),
        ),
      );

  testWidgets(
    'Office absent from store list remains selected without an exception',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        page(['Storeroom'], 'Office', changed: (_) => calls++),
      );
      expect(tester.takeException(), isNull);
      expect(field(tester).initialValue, 'Office');
      expect(
        dropdown(tester).items!.where((item) => item.value == 'Office'),
        hasLength(1),
      );
      expect(
        find.textContaining('Keep it or select another location.'),
        findsOneWidget,
      );
      expect(calls, 0);
    },
  );

  testWidgets('duplicate values and blank reference rows are safe', (
    tester,
  ) async {
    await tester.pumpWidget(
      page(['Office', 'Office', null, '', '  ', 'Storeroom'], 'Office'),
    );
    expect(tester.takeException(), isNull);
    expect(dropdown(tester).items!.map((item) => item.value).toList(), [
      'Office',
      'Storeroom',
    ]);
    expect(find.textContaining('isn’t in'), findsNothing);
  });

  testWidgets('empty reference list keeps saved location editable', (
    tester,
  ) async {
    await tester.pumpWidget(page([], 'Office'));
    expect(tester.takeException(), isNull);
    expect(field(tester).initialValue, 'Office');
    expect(field(tester).onChanged, isNotNull);
  });

  testWidgets('new count with no locations renders a disabled field', (
    tester,
  ) async {
    await tester.pumpWidget(page([], null));
    expect(tester.takeException(), isNull);
    expect(field(tester).onChanged, isNull);
    expect(find.textContaining('No locations are available.'), findsOneWidget);
  });

  testWidgets(
    'reference refresh and later record selection do not reset or crash',
    (tester) async {
      await tester.pumpWidget(page([], 'Office'));
      await tester.pumpWidget(
        page(['Office', 'Office', 'Storeroom'], 'Office'),
      );
      expect(tester.takeException(), isNull);
      expect(find.textContaining('isn’t in'), findsNothing);
      await tester.pumpWidget(page(['Storeroom'], 'Storeroom'));
      expect(
        tester
            .state<FormFieldState<String>>(
              find.byType(DropdownButtonFormField<String>),
            )
            .value,
        'Storeroom',
      );
      await tester.pumpWidget(page(['Storeroom'], null));
      expect(
        tester
            .state<FormFieldState<String>>(
              find.byType(DropdownButtonFormField<String>),
            )
            .value,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('user can explicitly replace the unlisted location', (
    tester,
  ) async {
    String? selected = 'Office';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => CountLocationField(
              locations: const ['Storeroom'],
              value: selected,
              onChanged: (value) => setState(() => selected = value),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Storeroom').last);
    await tester.pumpAndSettle();
    expect(selected, 'Storeroom');
    expect(find.textContaining('isn’t in'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fixed initial location stays read-only when unlisted', (
    tester,
  ) async {
    await tester.pumpWidget(page(['Storeroom'], 'Office', readOnly: true));
    expect(tester.takeException(), isNull);
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).initialValue,
      'Office',
    );
    expect(
      find.textContaining('The recorded location is kept.'),
      findsOneWidget,
    );
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
  });
}
