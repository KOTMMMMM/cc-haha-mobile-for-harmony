#include "napi/native_api.h"
#include "libtailscale_go.h"

#include <mutex>
#include <string>
#include <vector>

namespace {

std::mutex g_backendMutex;

using SimpleFunction = char* (*)();

struct SimpleWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    SimpleFunction function = nullptr;
    std::string result;
    bool succeeded = false;
};

struct StartWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string stateDir;
    std::string deviceModel;
    std::string osVersion;
    std::string controlURL;
    int fd = -1;
    bool restart = false;
    std::string result;
    bool succeeded = false;
};

struct AuthKeyWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string authKey;
    std::string result;
    bool succeeded = false;
};

struct NetworkWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string interfaceName;
    std::string result;
    bool succeeded = false;
};

void ResolveOrReject(napi_env env, napi_deferred deferred, bool succeeded, const std::string& result)
{
    napi_value value = nullptr;
    if (succeeded &&
        napi_create_string_utf8(env, result.c_str(), NAPI_AUTO_LENGTH, &value) == napi_ok) {
        napi_resolve_deferred(env, deferred, value);
        return;
    }
    napi_value message = nullptr;
    napi_value error = nullptr;
    napi_create_string_utf8(env, "Native Tailscale operation failed", NAPI_AUTO_LENGTH, &message);
    napi_create_error(env, nullptr, message, &error);
    napi_reject_deferred(env, deferred, error);
}

napi_value CreatePromise(napi_env env, napi_deferred* deferred)
{
    napi_value promise = nullptr;
    if (napi_create_promise(env, deferred, &promise) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to create native promise");
        return nullptr;
    }
    return promise;
}

void ExecuteSimple(napi_env env, void* data)
{
    (void)env;
    auto* work = static_cast<SimpleWork*>(data);
    std::lock_guard<std::mutex> lock(g_backendMutex);
    char* message = work->function();
    if (message == nullptr) {
        return;
    }
    work->result.assign(message);
    TSFreeString(message);
    work->succeeded = true;
}

void CompleteSimple(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<SimpleWork*>(data);
    ResolveOrReject(env, work->deferred, status == napi_ok && work->succeeded, work->result);
    napi_delete_async_work(env, work->work);
    delete work;
}

napi_value QueueSimple(napi_env env, SimpleFunction function, const char* resourceName)
{
    napi_deferred deferred = nullptr;
    napi_value promise = CreatePromise(env, &deferred);
    if (promise == nullptr) {
        return nullptr;
    }
    auto* work = new SimpleWork();
    work->deferred = deferred;
    work->function = function;
    napi_value resource = nullptr;
    if (napi_create_string_utf8(env, resourceName, NAPI_AUTO_LENGTH, &resource) != napi_ok ||
        napi_create_async_work(env, nullptr, resource, ExecuteSimple, CompleteSimple, work,
                               &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->work != nullptr) {
            napi_delete_async_work(env, work->work);
        }
        delete work;
        napi_throw_error(env, nullptr, "Failed to queue native operation");
        return nullptr;
    }
    return promise;
}

bool GetString(napi_env env, napi_value value, std::string& out)
{
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
        return false;
    }
    std::vector<char> buffer(length + 1, '\0');
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &copied) != napi_ok) {
        return false;
    }
    out.assign(buffer.data(), copied);
    return true;
}

void ExecuteStart(napi_env env, void* data)
{
    (void)env;
    auto* work = static_cast<StartWork*>(data);
    std::lock_guard<std::mutex> lock(g_backendMutex);
    char* message = work->restart
        ? TSBackendRestartWithTun(
              const_cast<char*>(work->stateDir.c_str()),
              const_cast<char*>(work->deviceModel.c_str()),
              const_cast<char*>(work->osVersion.c_str()),
              const_cast<char*>(work->controlURL.c_str()), work->fd)
        : TSBackendStart(
              const_cast<char*>(work->stateDir.c_str()),
              const_cast<char*>(work->deviceModel.c_str()),
              const_cast<char*>(work->osVersion.c_str()),
              const_cast<char*>(work->controlURL.c_str()));
    if (message == nullptr) {
        return;
    }
    work->result.assign(message);
    TSFreeString(message);
    work->succeeded = true;
}

void CompleteStart(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<StartWork*>(data);
    ResolveOrReject(env, work->deferred, status == napi_ok && work->succeeded, work->result);
    napi_delete_async_work(env, work->work);
    delete work;
}

void ExecuteAuthKey(napi_env env, void* data)
{
    (void)env;
    auto* work = static_cast<AuthKeyWork*>(data);
    std::lock_guard<std::mutex> lock(g_backendMutex);
    char* message = TSBackendLoginWithAuthKey(const_cast<char*>(work->authKey.c_str()));
    if (message == nullptr) {
        return;
    }
    work->result.assign(message);
    TSFreeString(message);
    work->succeeded = true;
}

void CompleteAuthKey(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<AuthKeyWork*>(data);
    ResolveOrReject(env, work->deferred, status == napi_ok && work->succeeded, work->result);
    napi_delete_async_work(env, work->work);
    delete work;
}

void ExecuteNetworkChanged(napi_env env, void* data)
{
    (void)env;
    auto* work = static_cast<NetworkWork*>(data);
    std::lock_guard<std::mutex> lock(g_backendMutex);
    char* message = TSBackendNetworkChanged(const_cast<char*>(work->interfaceName.c_str()));
    if (message == nullptr) {
        return;
    }
    work->result.assign(message);
    TSFreeString(message);
    work->succeeded = true;
}

void CompleteNetworkChanged(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<NetworkWork*>(data);
    ResolveOrReject(env, work->deferred, status == napi_ok && work->succeeded, work->result);
    napi_delete_async_work(env, work->work);
    delete work;
}

napi_value TsNetworkChanged(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "networkChanged requires an interface name");
        return nullptr;
    }
    auto* work = new NetworkWork();
    if (!GetString(env, args[0], work->interfaceName)) {
        delete work;
        napi_throw_type_error(env, nullptr, "interface name must be a string");
        return nullptr;
    }
    napi_deferred deferred = nullptr;
    napi_value promise = CreatePromise(env, &deferred);
    if (promise == nullptr) {
        delete work;
        return nullptr;
    }
    work->deferred = deferred;
    napi_value resource = nullptr;
    if (napi_create_string_utf8(env, "TailscaleNetworkChanged", NAPI_AUTO_LENGTH, &resource) != napi_ok ||
        napi_create_async_work(env, nullptr, resource, ExecuteNetworkChanged, CompleteNetworkChanged, work,
                               &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->work != nullptr) {
            napi_delete_async_work(env, work->work);
        }
        delete work;
        napi_throw_error(env, nullptr, "Failed to queue Tailscale network change");
        return nullptr;
    }
    return promise;
}

napi_value QueueStart(napi_env env, napi_callback_info info, bool restart)
{
    size_t argc = restart ? 5 : 4;
    napi_value args[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != (restart ? 5 : 4)) {
        napi_throw_type_error(env, nullptr, "Invalid Tailscale backend start arguments");
        return nullptr;
    }
    auto* work = new StartWork();
    work->restart = restart;
    if (!GetString(env, args[0], work->stateDir) || !GetString(env, args[1], work->deviceModel) ||
        !GetString(env, args[2], work->osVersion) || !GetString(env, args[3], work->controlURL)) {
        delete work;
        napi_throw_type_error(env, nullptr, "Tailscale backend arguments must be strings");
        return nullptr;
    }
    if (restart) {
        int32_t fd = -1;
        if (napi_get_value_int32(env, args[4], &fd) != napi_ok || fd < 0) {
            delete work;
            napi_throw_type_error(env, nullptr, "TUN descriptor must be a non-negative integer");
            return nullptr;
        }
        work->fd = fd;
    }
    napi_deferred deferred = nullptr;
    napi_value promise = CreatePromise(env, &deferred);
    if (promise == nullptr) {
        delete work;
        return nullptr;
    }
    work->deferred = deferred;
    napi_value resource = nullptr;
    const char* name = restart ? "TailscaleRestartWithTun" : "TailscaleBackendStart";
    if (napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &resource) != napi_ok ||
        napi_create_async_work(env, nullptr, resource, ExecuteStart, CompleteStart, work,
                               &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->work != nullptr) {
            napi_delete_async_work(env, work->work);
        }
        delete work;
        napi_throw_error(env, nullptr, "Failed to queue Tailscale backend start");
        return nullptr;
    }
    return promise;
}

napi_value TsVersion(napi_env env, napi_callback_info info)
{
    (void)info;
    std::lock_guard<std::mutex> lock(g_backendMutex);
    char* message = TSTailscaleVersion();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Tailscale version unavailable");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    return result;
}

napi_value TsHello(napi_env env, napi_callback_info info)
{
    (void)info;
    std::lock_guard<std::mutex> lock(g_backendMutex);
    char* message = TSHello();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Tailscale engine unavailable");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    return result;
}

napi_value TsTunFdProbe(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "tunFdProbe requires a descriptor");
        return nullptr;
    }
    int32_t fd = -1;
    if (napi_get_value_int32(env, args[0], &fd) != napi_ok || fd < 0) {
        napi_throw_type_error(env, nullptr, "TUN descriptor must be a non-negative integer");
        return nullptr;
    }
    std::lock_guard<std::mutex> lock(g_backendMutex);
    char* message = TSTunFDProbe(fd);
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "TUN descriptor probe failed");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    return result;
}

napi_value TsStart(napi_env env, napi_callback_info info)
{
    return QueueStart(env, info, false);
}

napi_value TsRestartWithTun(napi_env env, napi_callback_info info)
{
    return QueueStart(env, info, true);
}

napi_value TsLoginWithAuthKey(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "loginWithAuthKey requires a key");
        return nullptr;
    }
    auto* work = new AuthKeyWork();
    if (!GetString(env, args[0], work->authKey) || work->authKey.empty()) {
        delete work;
        napi_throw_type_error(env, nullptr, "Auth key must be a non-empty string");
        return nullptr;
    }
    napi_deferred deferred = nullptr;
    napi_value promise = CreatePromise(env, &deferred);
    if (promise == nullptr) {
        delete work;
        return nullptr;
    }
    work->deferred = deferred;
    napi_value resource = nullptr;
    if (napi_create_string_utf8(env, "TailscaleLoginWithAuthKey", NAPI_AUTO_LENGTH, &resource) != napi_ok ||
        napi_create_async_work(env, nullptr, resource, ExecuteAuthKey, CompleteAuthKey, work,
                               &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->work != nullptr) {
            napi_delete_async_work(env, work->work);
        }
        delete work;
        napi_throw_error(env, nullptr, "Failed to queue auth key login");
        return nullptr;
    }
    return promise;
}

napi_value TsAuthUrl(napi_env env, napi_callback_info info)
{
    (void)info;
    return QueueSimple(env, TSBackendAuthURL, "TailscaleAuthUrl");
}

napi_value TsVpnConfig(napi_env env, napi_callback_info info)
{
    (void)info;
    return QueueSimple(env, TSBackendVPNConfig, "TailscaleVpnConfig");
}

napi_value TsStatus(napi_env env, napi_callback_info info)
{
    (void)info;
    return QueueSimple(env, TSBackendStatus, "TailscaleStatus");
}

napi_value TsSnapshot(napi_env env, napi_callback_info info)
{
    (void)info;
    return QueueSimple(env, TSBackendSnapshot, "TailscaleSnapshot");
}

napi_value TsStop(napi_env env, napi_callback_info info)
{
    (void)info;
    return QueueSimple(env, TSBackendStop, "TailscaleStop");
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor properties[] = {
        {"tsVersion", nullptr, TsVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"tsHello", nullptr, TsHello, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"tsStart", nullptr, TsStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"tsRestartWithTun", nullptr, TsRestartWithTun, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"tsLoginWithAuthKey", nullptr, TsLoginWithAuthKey, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"tsAuthUrl", nullptr, TsAuthUrl, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"tsVpnConfig", nullptr, TsVpnConfig, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"tsStatus", nullptr, TsStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"tsSnapshot", nullptr, TsSnapshot, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"tsStop", nullptr, TsStop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"tsTunFdProbe", nullptr, TsTunFdProbe, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"tsNetworkChanged", nullptr, TsNetworkChanged, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
    return exports;
}

napi_module g_module = {
    1,
    0,
    nullptr,
    Init,
    "tailscale_ohos_bridge",
    nullptr,
    {nullptr, nullptr, nullptr, nullptr},
};

} // namespace

extern "C" __attribute__((constructor)) void RegisterTailscaleBridgeModule()
{
    napi_module_register(&g_module);
}
