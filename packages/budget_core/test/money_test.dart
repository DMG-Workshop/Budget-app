import 'package:budget_core/budget_core.dart';
import 'package:test/test.dart';

void main() {
  group('Money.tryParse', () {
    test('reads plain numbers', () {
      expect(Money.tryParse(12.34), const Money(1234));
      expect(Money.tryParse(5), const Money(500));
      expect(Money.tryParse(0), Money.zero);
    });

    test('strips currency symbols and grouping', () {
      expect(Money.tryParse(r'£1,234.56'), const Money(123456));
      expect(Money.tryParse(r'$1,234.56'), const Money(123456));
      expect(Money.tryParse('1 234.56 GBP'), const Money(123456));
    });

    test('reads a European decimal comma', () {
      expect(Money.tryParse('1.234,56'), const Money(123456));
      expect(Money.tryParse('1,23'), const Money(123));
    });

    test('treats a comma before three digits as grouping', () {
      expect(Money.tryParse('1,234'), const Money(123400));
    });

    test('reads accounting parentheses as negative', () {
      expect(Money.tryParse('(45.00)'), const Money(-4500));
      expect(Money.tryParse('-45.00'), const Money(-4500));
      expect(Money.tryParse(r'-£45.00'), const Money(-4500));
    });

    test('rounds half away from zero', () {
      expect(Money.tryParse(12.345), const Money(1235));
      expect(Money.tryParse(12.344), const Money(1234));
    });

    test('returns null rather than a wrong number', () {
      expect(Money.tryParse(null), isNull);
      expect(Money.tryParse('not a number'), isNull);
      expect(Money.tryParse(''), isNull);
      expect(Money.tryParse(<String>[]), isNull);
    });
  });

  group('arithmetic', () {
    test('sums exactly where doubles would drift', () {
      // 0.1 + 0.2 != 0.3 in binary floating point. In minor units it does.
      final sum = Money.sum(const [Money(10), Money(20)]);
      expect(sum, const Money(30));

      final many = Money.sum(List.filled(1000, const Money(1010)));
      expect(many, const Money(1010000));
    });

    test('subtracts into a deficit', () {
      expect(const Money(100000) - const Money(250000), const Money(-150000));
      expect((const Money(100000) - const Money(250000)).isNegative, isTrue);
    });

    test('annualises by multiplication, not repeated addition', () {
      expect(const Money(2499) * 12, const Money(29988));
    });

    test('fractionOf a zero total is zero, not NaN', () {
      expect(const Money(500).fractionOf(Money.zero), 0);
      expect(const Money(2500).fractionOf(const Money(10000)), 0.25);
    });
  });

  group('formatting', () {
    test('always shows two minor digits', () {
      expect(const Money(5).toString(), '0.05');
      expect(const Money(50).toString(), '0.50');
      expect(const Money(123456).toString(), '1234.56');
      expect(const Money(-4500).toString(), '-45.00');
    });
  });
}
