import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_time/ui/overlay/guardian_copy.dart';

void main() {
  group('GuardianCopy.bucketForHour', () {
    test('evening hours bucket to earlyEvening', () {
      expect(GuardianCopy.bucketForHour(21), NightBucket.earlyEvening);
      expect(GuardianCopy.bucketForHour(23), NightBucket.earlyEvening);
    });

    test('after-midnight before 2am buckets to lateNight', () {
      expect(GuardianCopy.bucketForHour(0), NightBucket.lateNight);
      expect(GuardianCopy.bucketForHour(1), NightBucket.lateNight);
    });

    test('2am-5am buckets to smallHours', () {
      expect(GuardianCopy.bucketForHour(2), NightBucket.smallHours);
      expect(GuardianCopy.bucketForHour(4), NightBucket.smallHours);
    });

    test('5am-9am buckets to preDawn', () {
      expect(GuardianCopy.bucketForHour(5), NightBucket.preDawn);
      expect(GuardianCopy.bucketForHour(8), NightBucket.preDawn);
    });

    test('hours wrap with modulo', () {
      expect(GuardianCopy.bucketForHour(24), GuardianCopy.bucketForHour(0));
      expect(GuardianCopy.bucketForHour(26), GuardianCopy.bucketForHour(2));
    });
  });

  group('GuardianCopy lines', () {
    test('block line headline differs across buckets', () {
      final evening = GuardianCopy.blockLineForHour(22).headline;
      final small = GuardianCopy.blockLineForHour(3).headline;
      expect(evening, isNot(equals(small)));
      expect(evening, isNotEmpty);
      expect(small, isNotEmpty);
    });

    test('grant banner label is non-empty for every bucket', () {
      for (final h in [22, 1, 3, 6]) {
        expect(GuardianCopy.grantBannerLabelForHour(h), isNotEmpty);
      }
    });
  });
}
