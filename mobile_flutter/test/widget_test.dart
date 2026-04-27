// Smoke test for the mobile_flutter package. The full `MobileReminderApp`
// requires platform plugins (Firebase, AndroidAlarmManager, ...) that are not
// available in unit tests, so this file just verifies that the test harness
// itself runs.
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('test harness runs', () {
    expect(1 + 1, 2);
  });
}
