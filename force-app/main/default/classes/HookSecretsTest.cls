/**
 * @description Tests for secrets and rotation (AC-SEC-2, AC-SEC-3), the clock,
 * the backoff and the config defaults.
 */
@IsTest
private class HookSecretsTest {
  @IsTest
  static void setSecretMakesOrChangesTheRecord() {
    Hook.setSecret('a', 'one');
    Hook.setSecret('a', 'two');
    Assert.areEqual(new List<String>{ 'two' }, HookSecrets.valuesFor('a'));
    Assert.areEqual(1, [SELECT COUNT() FROM Hook_Secret__c WHERE Name = 'a']);
  }

  @IsTest
  static void aLongNameThrows() {
    try {
      Hook.setSecret('n'.repeat(39), 'x');
      Assert.fail('Expected a HookException');
    } catch (HookException e) {
      Assert.isTrue(e.getMessage().contains('38'), e.getMessage());
    }
  }

  @IsTest
  static void rotateKeepsThePreviousValueUntilTheGraceEnds() {
    Hook.setSecret('a', 'old');
    String fresh = Hook.rotateSecret('a', 2);
    Assert.isTrue(fresh.startsWith('whsec_'));
    Assert.areEqual(
      32,
      EncodingUtil.base64Decode(fresh.removeStart('whsec_')).size()
    );
    Assert.areEqual(
      new List<String>{ fresh, 'old' },
      HookSecrets.valuesFor('a')
    );

    HookClock.fixedSeconds = Datetime.now().addHours(3).getTime() / 1000;
    Assert.areEqual(new List<String>{ fresh }, HookSecrets.valuesFor('a'));
  }

  @IsTest
  static void rotateAMissingSecretMakesIt() {
    String fresh = Hook.rotateSecret('new_one', 1);
    Assert.areEqual(
      new List<String>{ fresh },
      HookSecrets.valuesFor('new_one')
    );
  }

  @IsTest
  static void valuesForReadsACommaList() {
    Hook.setSecret('a', '1');
    Hook.setSecret('b', '2');
    Assert.areEqual(
      new List<String>{ '1', '2' },
      HookSecrets.valuesFor(' a, b ,missing')
    );
    Assert.areEqual(new List<String>(), HookSecrets.valuesFor(null));
  }

  @IsTest
  static void backoffDoublesAndStopsAtTheCap() {
    HookBackoff.jitterEnabled = false;
    Assert.areEqual(60, HookBackoff.delaySeconds(1, 60, 3600));
    Assert.areEqual(120, HookBackoff.delaySeconds(2, 60, 3600));
    Assert.areEqual(480, HookBackoff.delaySeconds(4, 60, 3600));
    Assert.areEqual(3600, HookBackoff.delaySeconds(30, 60, 3600));
    HookBackoff.jitterEnabled = true;
    for (Integer i = 0; i < 20; i++) {
      Assert.isTrue(
        HookBackoff.delaySeconds(30, 60, 3600) <= 3600,
        'the cap holds with jitter'
      );
    }
    for (Integer i = 0; i < 20; i++) {
      Integer d = HookBackoff.delaySeconds(3, 100, 3600);
      Assert.isTrue(d >= 320 && d <= 480, String.valueOf(d));
    }
  }

  @IsTest
  static void configHasDefaultsWithNoRecord() {
    HookConfig.current = new Hook_Setting__mdt();
    Assert.areEqual(10, HookConfig.batchSize());
    Assert.areEqual(10000, HookConfig.timeoutMs());
    Assert.areEqual(10, HookConfig.maxAttempts());
    Assert.areEqual(60, HookConfig.baseDelaySeconds());
    Assert.areEqual(21600, HookConfig.maxDelaySeconds());
    Assert.areEqual(50, HookConfig.disableAfterFailures());
    Assert.areEqual(10, HookConfig.leaseMinutes());
    Assert.areEqual(30, HookConfig.retentionDays());
    Assert.areEqual(HookQueueChannel.NAME, HookConfig.defaultChannel());
  }

  @IsTest
  static void configCapsTheBatchAndTheTimeout() {
    Hook_Setting__mdt s = HookTestSupport.settings();
    s.Batch_Size__c = 500;
    s.Timeout_Ms__c = 1000;
    Assert.areEqual(100, HookConfig.batchSize());
    s.Timeout_Ms__c = 999999;
    Assert.areEqual(120000, HookConfig.timeoutMs());
    Assert.areEqual(1, HookConfig.batchSize());
    s.Batch_Size__c = 20;
    s.Timeout_Ms__c = 10000;
    Assert.areEqual(
      12,
      HookConfig.batchSize(),
      'total callout time stays below 120 s'
    );
  }

  @IsTest
  static void theClockCanBeFixed() {
    HookClock.fixedSeconds = 1700000000L;
    Assert.areEqual(1700000000L, HookClock.nowSeconds());
    Assert.areEqual(Datetime.newInstance(1700000000000L), HookClock.now());
    HookClock.fixedSeconds = null;
    Assert.isTrue(
      Math.abs(HookClock.nowSeconds() - Datetime.now().getTime() / 1000) <= 1
    );
  }

  @IsTest
  static void setSecretRevokesThePreviousValue() {
    Hook.setSecret('a', 'old');
    Hook.rotateSecret('a', 24);
    Hook.setSecret('a', 'fresh');
    Assert.areEqual(new List<String>{ 'fresh' }, HookSecrets.valuesFor('a'));
  }
}
