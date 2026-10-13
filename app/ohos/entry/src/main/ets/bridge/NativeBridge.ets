import { FlutterEngine, MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { bundleManager, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { pushService } from '@kit.PushKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'NativeBridge';

/**
 * HarmonyOS side of the `couple_ledger/native` channel (mirrors
 * MainActivity.kt on Android): app directories, notification permission
 * and the Push Kit token used for background budget alerts.
 */
class NativeHandler implements MethodCallHandler {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'platform':
        result.success('ohos');
        break;
      case 'filesDir':
        result.success(this.context.filesDir);
        break;
      case 'appVersion':
        this.appVersion(result);
        break;
      case 'notificationsEnabled':
        notificationManager.isNotificationEnabled()
          .then((enabled: boolean) => result.success(enabled))
          .catch(() => result.success(false));
        break;
      case 'requestNotificationPermission':
        notificationManager.requestEnableNotification(this.context)
          .then(() => result.success(true))
          .catch((e: BusinessError) => {
            hilog.warn(0x0000, TAG, 'requestEnableNotification failed: %{public}d', e.code);
            result.success(false);
          });
        break;
      case 'pushToken':
        pushService.getToken()
          .then((token: string) => result.success(token))
          .catch((e: BusinessError) => {
            hilog.error(0x0000, TAG, 'getToken failed: %{public}d %{public}s', e.code, e.message);
            result.success(null);
          });
        break;
      default:
        result.notImplemented();
    }
  }

  private appVersion(result: MethodResult): void {
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      .then((info: bundleManager.BundleInfo) => result.success(info.versionName))
      .catch(() => result.success(''));
  }
}

export function registerNativeBridge(engine: FlutterEngine, context: common.UIAbilityContext): void {
  const channel = new MethodChannel(engine.dartExecutor, 'couple_ledger/native');
  channel.setMethodCallHandler(new NativeHandler(context));
}
