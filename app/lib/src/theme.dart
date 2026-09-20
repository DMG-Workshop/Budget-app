import 'package:flutter/material.dart';

/// Colours for the spending breakdown.
///
/// Not chosen by eye. These are validated against the light and dark chart
/// surfaces for lightness band, chroma floor, colour-vision-deficiency
/// separation, normal-vision separation and contrast. Two advisories came back
/// and both are mitigated in the widget rather than ignored:
///
///  * light mode: `wants` sits at 2.74:1 against the surface, under the 3:1
///    bar, which obliges visible labels or a table view. The breakdown ships
///    both.
///  * dark mode: `wants` and `leaks` separate by only 7.2 deltaE under
///    deuteranopia, inside the band that is permissible only with secondary
///    encoding. The 2px gaps between segments, the direct labels and the icon
///    on the leak legend entry are that encoding — removing any of them breaks
///    the guarantee, so do not "tidy" them away.
class ChartColors {
  const ChartColors({
    required this.needs,
    required this.wants,
    required this.leaks,
    required this.surface,
    required this.grid,
  });

  /// Categorical slot 1 (blue) and slot 3 (aqua) for the two spending kinds,
  /// and the reserved `critical` status step for waste — leaks are a state,
  /// not a series, and they always ship with an icon and a label.
  factory ChartColors.of(Brightness brightness) =>
      brightness == Brightness.dark
          ? const ChartColors(
              needs: Color(0xFF3987E5),
              wants: Color(0xFF199E70),
              leaks: Color(0xFFD03B3B),
              surface: Color(0xFF1A1A19),
              grid: Color(0xFF383835),
            )
          : const ChartColors(
              needs: Color(0xFF2A78D6),
              wants: Color(0xFF1BAF7A),
              leaks: Color(0xFFD03B3B),
              surface: Color(0xFFFCFCFB),
              grid: Color(0xFFF0EFEC),
            );

  final Color needs;
  final Color wants;
  final Color leaks;

  /// The colour the 2px separators are painted in, so segments never touch.
  final Color surface;

  final Color grid;
}

/// Status steps, used for the cashflow verdict and the leak severities.
///
/// Reserved: never reused as a series colour, and never the only carrier of
/// meaning — every use here is paired with a word.
class StatusColors {
  const StatusColors._();

  static const Color good = Color(0xFF0CA30C);
  static const Color warning = Color(0xFFFAB219);
  static const Color serious = Color(0xFFEC835A);
  static const Color critical = Color(0xFFD03B3B);
}

/// Coldwater's Material 3 theme.
///
/// A cold blue seed, because the app is a cold shower and the palette should
/// not apologise for it.
class ColdwaterTheme {
  const ColdwaterTheme._();

  static const Color seed = Color(0xFF2A78D6);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: ChartColors.of(brightness).surface,
      cardTheme: CardThemeData(
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: ChartColors.of(brightness).surface,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
      ),
      // Tabular figures everywhere a number appears, so columns of money line
      // up and a changing value does not make the row jitter.
      textTheme: const TextTheme().apply(
        fontFamilyFallback: const ['monospace'],
      ),
    );
  }

  /// The one text style that must never be proportional: money.
  static TextStyle money(TextStyle? base) =>
      (base ?? const TextStyle()).copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
      );
}
