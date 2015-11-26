//
//  jsb_cocosruntime.mm
//  CocosJSRuntime
//
//  Created by WenhaiLin on 15/10/23.
//
#include "jsb_cocosruntime.h"
#include "cocos2d_specifics.hpp"

#import "CocosRuntime.h"
#import "RTNetworkHelper.h"

#import "MttGameEngine.h"
#import "../controller/PreRunGame.h"
#import "../controller/LoadingDelegate.h"
#import "../model/ChannelConfig.h"

static std::function<void (int percent, bool isFailed)> s_downloadCallback;

class JSPreloadCallbackWrapper: public JSCallbackWrapper {
public:
    void eventCallbackFunc(int percent, bool isFailed)
    {
        cocos2d::Director::getInstance()->getScheduler()->performFunctionInCocosThread([this, percent, isFailed]{
            if (s_downloadCallback == nullptr) {
                return;
            }
            JSContext *cx = ScriptingCore::getInstance()->getGlobalContext();
            JS::RootedObject thisObj(cx, getJSCallbackThis().toObjectOrNull());
            JS::RootedValue callback(cx, getJSCallbackFunc());
            JS::RootedValue retval(cx);
            
            if (!callback.isNullOrUndefined())
            {
                char statusText[80];
                sprintf(statusText, "{\"percent\":%d, \"isCompleted\":%s, \"isFailed\":%s, \"errorCode\":\"%s\"}", percent,
                        (percent >= 100 && !isFailed) ? "true" : "false",
                        isFailed ? "true" : "false", isFailed ? "err_network" : "");
                
                JSB_AUTOCOMPARTMENT_WITH_GLOBAL_OBJCET

                JS::RootedValue outVal(cx);
                jsval strVal = c_string_to_jsval(cx, statusText);
                bool ok = JS_ParseJSON(cx, JS::RootedString(cx, strVal.toString()), &outVal);
                if (ok) {
                    JS_CallFunctionValue(cx, thisObj, callback, JS::HandleValueArray::fromMarkedLocation(1, &outVal.get()), &retval);
                }
            }
        });
    }
};

class RTCallbacksComponent: public cocos2d::Component {
public:
    RTCallbacksComponent() {
        setName(NAME);
    }
    
    virtual ~RTCallbacksComponent() {
        s_downloadCallback = nullptr;
    }
    
    JSBinding::Dictionary callbacks;
    static const std::string NAME;
};

const std::string RTCallbacksComponent::NAME = "JSB_RTCallback";

//资源分组下载进度的Adapter
typedef void(^RTPreloadCallback)(int progress, bool isFailed);

@interface LoadingAdapter4ResGroups : NSObject <LoadingDelegate>
{
    RTPreloadCallback reloadCallback;
}

- (LoadingAdapter4ResGroups*) initWith: (RTPreloadCallback) callback;

@end

@implementation LoadingAdapter4ResGroups

- (LoadingAdapter4ResGroups*) initWith:(RTPreloadCallback)callback
{
    self = [super init];
    if (self != nil) {
        reloadCallback = callback;
    }
    
    return self;
}

- (void) onLoadingError
{
    printf("%s\n", __FUNCTION__);
    reloadCallback(-1, TRUE);
}

- (void) onLoadingCompleted
{
    printf("%s\n", __FUNCTION__);
    reloadCallback(100, FALSE);
}

- (void) onLoadingProgress:(float)progress max:(float)max
{
    if (progress >= 100.0f) {
        progress = 99.0f;
    }
    reloadCallback(progress, FALSE);
}

@end

USING_NS_CC;

static bool JSB_runtime_preload(JSContext *cx, uint32_t argc, jsval *vp)
{
    JSB_PRECONDITION2( argc == 3, cx, false, "JSB_runtime_preload Invalid number of arguments" );
    
    auto args = JS::CallArgsFromVp(argc, vp);
    bool ok = true;

    std::string resGroups = "";
    auto arg0Handle = args.get(0);

    if (JS_IsArrayObject(cx, arg0Handle)) {
        ValueVector arrVal;
        ok = jsval_to_ccvaluevector(cx, arg0Handle, &arrVal);

        for (size_t i = 0; i < arrVal.size(); i++) {
            if (! resGroups.empty()) {
                resGroups += ":";
            }
            resGroups += arrVal[i].asString();
        }
    }
    else {
        ok &= jsval_to_std_string(cx, args.get(0), &resGroups);
    }

    JSB_PRECONDITION2(ok, cx, false, "Error processing arguments");

    do {
        if (JS_TypeOfValue(cx, args[1]) == JSTYPE_FUNCTION) {
            auto cbObject= args.get(2).toObjectOrNull();;
            
            auto proxy = jsb_get_js_proxy(cbObject);
            auto loadLayer = (cocos2d::Layer*)(proxy ? proxy->ptr : nullptr);
            auto callbackComp = static_cast<RTCallbacksComponent*>(loadLayer->getComponent(RTCallbacksComponent::NAME));
            if (callbackComp == nullptr) {
                callbackComp = new (std::nothrow) RTCallbacksComponent;
                callbackComp->autorelease();
                loadLayer->addComponent(callbackComp);
            }
            
            auto cbWapper = new (std::nothrow) JSPreloadCallbackWrapper;
            cbWapper->autorelease();
            cbWapper->setJSCallbackFunc(args.get(1));
            cbWapper->setJSCallbackThis(args.get(2));
            callbackComp->callbacks.insert("JSPreloadCallbackWrapper", cbWapper);
            
            auto lambda = [cbWapper](int percent, bool isFailed){
                cbWapper->eventCallbackFunc(percent, isFailed);
            };
            s_downloadCallback = lambda;
        }
        else {
            s_downloadCallback = nullptr;
        }
    } while (false);
    
    if (s_downloadCallback) {
        NSString* groups = [NSString stringWithUTF8String:resGroups.c_str()];
        LoadingAdapter4ResGroups *delegate = [[LoadingAdapter4ResGroups alloc] initWith:^(int progress, bool isFailed){
                if (s_downloadCallback) {
                    s_downloadCallback(progress, isFailed);
                }
        }];
        [CocosRuntime preloadResGroups: groups delegate:delegate];
    }
    
    args.rval().setUndefined();
    
    return true;
}

static bool JSB_runtime_getNetworkType(JSContext *cx, uint32_t argc, jsval *vp)
{
    auto args = JS::CallArgsFromVp(argc, vp);
    int status = [RTNetworkHelper getNetworkType];
    args.rval().set(INT_TO_JSVAL(status));
    
    return true;
}

static bool JSB_runtime_loadRomoteImage(JSContext *cx, uint32_t argc, jsval *vp)
{
    auto args = JS::CallArgsFromVp(argc, vp);
    if (argc >= 2) {
        std::string imageConfig;
        bool ok = true;
        ok &= jsval_to_std_string(cx, args.get(0), &imageConfig);
        JSB_PRECONDITION2(ok, cx, false, "JSB_runtime_loadRomoteImage:Error processing arguments");
        
        if (JS_TypeOfValue(cx, args[1]) == JSTYPE_FUNCTION) {
            JSObject *obj = JS_THIS_OBJECT(cx, vp);
            
            std::shared_ptr<JSFunctionWrapper> func(new JSFunctionWrapper(cx, obj, args.get(1)));
            
            [CocosRuntime downloadAvatarImageFile:[NSString stringWithUTF8String:imageConfig.c_str()] extension:0 callback:^(NSString *resultJson, long extension) {
                
                JS::RootedValue outVal(cx);
                jsval resultVal = c_string_to_jsval(cx, [resultJson cStringUsingEncoding:NSUTF8StringEncoding]);
                bool ok = JS_ParseJSON(cx, JS::RootedString(cx, resultVal.toString()), &outVal);
                if (ok) {
                    JS::RootedValue rval(cx);
                    ok = func->invoke(1, outVal.address(), &rval);
                    if (!ok && JS_IsExceptionPending(cx)) {
                        JS_ReportPendingException(cx);
                    }
                }
            }];
        }
        else {
            printf("%s:Error processing arguments\n", __FUNCTION__);
            
        }
    }
    args.rval().setUndefined();
    
    return true;
}

extern JSObject *jsb_cocos2d_Director_prototype;

static bool JSB_runtime_director_end(JSContext *cx, uint32_t argc, jsval *vp)
{
    auto args = JS::CallArgsFromVp(argc, vp);
    
    [[MttGameEngine getEngineDelegate] x5GamePlayer_stop_game_engine];
    
    args.rval().setUndefined();
    
    return true;
}

void jsb_register_cocosruntime(JSContext* cx, JS::HandleObject global)
{
    JS::RootedObject runtimeObj(cx);
    get_or_create_js_obj(cx, global, "runtime", &runtimeObj);

    JS_DefineFunction(cx, runtimeObj, "preload", JSB_runtime_preload, 3,
                      JSPROP_READONLY | JSPROP_PERMANENT | JSPROP_ENUMERATE );
    JS_DefineFunction(cx, runtimeObj, "getNetworkType", JSB_runtime_getNetworkType, 0,
                      JSPROP_READONLY | JSPROP_PERMANENT | JSPROP_ENUMERATE );
    
    JS::RootedObject jsbObj(cx);
    get_or_create_js_obj(cx, global, "jsb", &jsbObj);
    JS_DefineFunction(cx, jsbObj, "loadRemoteImg", JSB_runtime_loadRomoteImage, 2,
                      JSPROP_READONLY | JSPROP_PERMANENT | JSPROP_ENUMERATE );
    
    //把游戏相关配置及渠道ID、设备ID传到js层
    NSMutableDictionary* gameConfig = [[PreRunGame getGameConfig] getGameConfig];
    [gameConfig setObject:[ChannelConfig getChannelID] forKey:@"channel_id"];
    [gameConfig setObject:[[[UIDevice currentDevice] identifierForVendor] UUIDString] forKey:@"device_id"];
    //boot_args = game_engine_init参数game info
    //[gameConfig setObject:@"" forKey:@"boot_args"];
    NSString* gameConfigJson = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:gameConfig options:NSJSONWritingPrettyPrinted error:nil] encoding:NSUTF8StringEncoding];
    
    JS::RootedValue outVal(cx);
    jsval strVal = c_string_to_jsval(cx, [gameConfigJson cStringUsingEncoding:NSUTF8StringEncoding]);
    bool ok = JS_ParseJSON(cx, JS::RootedString(cx, strVal.toString()), &outVal);
    if (ok)
    {
        JS_DefineProperty(cx, runtimeObj, "config", outVal, JSPROP_ENUMERATE | JSPROP_PERMANENT);
    }
    else
    {
        printf("%s:parse game config to json fail\n", __FUNCTION__);
    }
    
    //拦截Director::end,走QQ浏览器runtime游戏退出流程
    JS::RootedObject ccObj(cx);
    JS::RootedValue tmpVal(cx);
    JS::RootedObject tmpObj(cx);
    get_or_create_js_obj(cx, global, "cc", &ccObj);
    JS_GetProperty(cx, ccObj, "Director", &tmpVal);
    tmpObj = tmpVal.toObjectOrNull();
    tmpObj.set(jsb_cocos2d_Director_prototype);
    JS_DefineFunction(cx, tmpObj, "end", JSB_runtime_director_end, 0, JSPROP_ENUMERATE | JSPROP_PERMANENT);
    
}
