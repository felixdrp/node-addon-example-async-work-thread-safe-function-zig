// Example based on https://blog.risingstack.com/using-buffers-node-js-c-plus-plus/
// https://stackoverflow.com/questions/58960713/how-to-use-napi-threadsafe-function-for-nodejs-native-addon
// we will have to start sending task result while the task is still in progress.
// This is the scenario where Asynchronous Thread-safe Function Calls come for our help.
// https://github.com/nodejs/node-addon-examples/blob/main/async_work_thread_safe_function/napi/binding.c
// https://napi.inspiredware.com/special-topics/thread-safe-functions.html

const c = @cImport({
    @cInclude("node_api.h");
});

const std = @import("std");

const PRIME_COUNT: u32 = 100000;
const REPORT_EVERY: u32 = 1000;

const AddonData = packed struct {
    work: c.napi_async_work,
    tsfn: c.napi_threadsafe_function,
};

// This function is responsible for converting data coming in from the worker
// thread to napi_value items that can be passed into JavaScript, and for
// calling the JavaScript function.
fn CallJs(
    env: c.napi_env,
    js_cb: c.napi_value,
    context: ?*anyopaque,
    // data = the_prime
    data: ?*anyopaque 
) callconv(.C) void {
    // This parameter is not used.
    _ = context;
    var status: c.napi_status = undefined;

    // Retrieve the prime from the item created by the worker thread.
    var prime_container = @intToPtr(*[]u32, @ptrToInt(data)).*;
    var the_prime = prime_container[0];

    // env and js_cb may both be NULL if Node.js is in its cleanup phase, and
    // items are left over from earlier thread-safe calls from the worker thread.
    // When env is NULL, we simply skip over the call into Javascript and free the
    // items.
    if (env != null) {
        var js_undefined: c.napi_value = undefined;
        var js_the_prime: c.napi_value = undefined;

        // Convert the integer to a napi_value.
        status = c.napi_create_uint32(env, the_prime, &js_the_prime);

        // Retrieve the JavaScript `undefined` value so we can use it as the `this`
        // value of the JavaScript function call.
        status = c.napi_get_undefined(env, &js_undefined);

        // Call the JavaScript function and pass it the prime that the secondary
        // thread found.
        status = c.napi_call_function(env,
                                    js_undefined,
                                    js_cb,
                                    1,
                                    &js_the_prime,
                                    null
        );
    }

    // Free the item created by the worker thread.
    std.heap.raw_c_allocator.free(prime_container);
}

// This function runs on a worker thread. It has no access to the JavaScript
// environment except through the thread-safe function.
fn ExecuteWork(
    env: c.napi_env,
    data: ?*anyopaque
) callconv(.C) void {
    _ = env;
    var addon_data: AddonData = @intToPtr(*AddonData, @ptrToInt(data)).*;

    var idx_outer:u32 = 2;
    var idx_inner:u32 = undefined;
    var prime_count:u32 = 0;
    var status: c.napi_status = undefined;

    // We bracket the use of the thread-safe function by this thread by a call to
    // napi_acquire_threadsafe_function() here, and by a call to
    // napi_release_threadsafe_function() immediately prior to thread exit.
    status = c.napi_acquire_threadsafe_function(addon_data.tsfn);

    // Find the first 1000 prime numbers using an extremely inefficient algorithm.
    while (prime_count < PRIME_COUNT) : (idx_outer += 1) {
        idx_inner = 2;
        while (idx_inner < idx_outer) : (idx_inner += 1) {
            if (idx_outer % idx_inner == 0) {
                break;
            }
        }

        if (idx_inner < idx_outer) {
            continue;
        }

        // We found a prime. If it's the tenth since the last time we sent one to
        // JavaScript, send it to JavaScript
        prime_count += 1;
        if ((prime_count % REPORT_EVERY) == 0) {
            // Save the prime number to the heap. The JavaScript marshaller (CallJs)
            // will free this item after having sent it to JavaScript.
            // int* the_prime = malloc(sizeof(*the_prime));
            // *the_prime = idx_outer;
            var the_prime = std.heap.raw_c_allocator.alloc(@TypeOf(idx_outer), 1) catch |err| { // <-- capture err here
                std.debug.print("Oops! {}\n", .{err});
                return ;
            };
            the_prime[0] = idx_outer;

            // Initiate the call into JavaScript. The call into JavaScript will not
            // have happened when this function returns, but it will be queued.
            status = c.napi_call_threadsafe_function(
                addon_data.tsfn,
                @intToPtr(?*anyopaque, @ptrToInt(&the_prime)),
                c.napi_tsfn_blocking);
        }
    }

    // Indicate that this thread will make no further use of the thread-safe function.
    status = c.napi_release_threadsafe_function(addon_data.tsfn,
                                            c.napi_tsfn_release);
}

// This function runs on the main thread after `ExecuteWork` exits.
fn WorkComplete(
    env: c.napi_env,
    status: c.napi_status,
    data: ?*anyopaque
) callconv(.C) void {
    _ = status;
    var status_local: c.napi_status = undefined;
    var addon_data: AddonData = @intToPtr(*[]AddonData, @ptrToInt(data)).*[0];
    // Clean up the thread-safe function and 
    // the work item associated with this run.
    status_local = c.napi_release_threadsafe_function(addon_data.tsfn,
                                                    c.napi_tsfn_release);
    status_local = c.napi_delete_async_work(env, addon_data.work);

    // Set both values to NULL so JavaScript can order a new run of the thread.
    addon_data.work = null;
    addon_data.tsfn = null;
}

fn StartThread(env: c.napi_env, info: c.napi_callback_info) callconv(.C) c.napi_value {
    var argc: usize = 1;
    var argv: [1]c.napi_value = .{};
    var js_cb: c.napi_value = undefined;
    var work_name: c.napi_value = undefined;
    var global: c.napi_value = undefined;
    var addon_data: AddonData = undefined;
    var status: c.napi_status = c.napi_get_global(env, &global);

    // Retrieve the JavaScript callback we should call with items generated by the
    // worker thread, and the per-addon data.
    status = c.napi_get_cb_info(
        env,
        info,
        &argc,
        &argv,
        null,
        @intToPtr(
            [*c]?*anyopaque,
            @ptrToInt(&addon_data))
    );
    js_cb = argv[0];

    if (status != c.napi_ok) {
        std.log.warn("napi_get_cb_info not ok", .{});
    }

    // Ensure that no work is currently in progress.
    if (addon_data.work == null) {
        std.log.warn("Only one work item must exist at a time", .{});
    }

    // Create a string to describe this asynchronous operation.
    status = c.napi_create_string_utf8(
        env,
        "Node-API Thread-safe Call from Async Work Item",
        c.NAPI_AUTO_LENGTH,
        &work_name);
    // Convert the callback retrieved from JavaScript into a thread-safe function
    // which we can call from a worker thread.
    status = c.napi_create_threadsafe_function(
        env,
        js_cb,
        null,
        work_name,
        0,
        1,
        null,
        null,
        // context
        // https://stackoverflow.com/questions/58241265/make-node-js-exit-regardless-of-a-native-module-async-call-pending
        null,
        &CallJs,
        &addon_data.tsfn);

    // Create an async work item, passing in the addon data, which will give the
    // worker thread access to the above-created thread-safe function.
    status = c.napi_create_async_work(env,
                                    null,
                                    work_name,
                                    ExecuteWork,
                                    WorkComplete,
                                    &addon_data,
                                    &(addon_data.work));

    // Queue the work item for execution.
    status = c.napi_queue_async_work(env, addon_data.work);

    // This causes `undefined` to be returned to JavaScript.
    return null;
}

// Free the per-addon-instance data.
fn addon_getting_unloaded(
    env: c.napi_env,
    data: ?*anyopaque,
    hint: ?*anyopaque
) callconv(.C) void {
    _ = hint;
    _ = env;
  var addon_data: []AddonData  = @intToPtr(*[]AddonData, @ptrToInt(data)).*;
  if (addon_data[0].work == null) {
    std.log.warn("No work item in progress at module unload", .{});
  }
  std.heap.raw_c_allocator.free(addon_data);
}

export fn napi_register_module_v1(env: c.napi_env, exports: c.napi_value) c.napi_value {
    var status: c.napi_status = undefined;
    var result: c.napi_value = undefined;

    // Define addon-level data associated with this instance of the addon.
    var addon_data = std.heap.raw_c_allocator.alloc(AddonData, 1) catch |err| { // <-- capture err here
        std.debug.print("Oops! {}\n", .{err});
        status = c.napi_create_string_utf8(
            env,
            "Error allocating memory",
            c.NAPI_AUTO_LENGTH,
            &result);
        return result;
    };
    addon_data[0].work = null;

    // Define the properties that will be set on exports.
    var start_work = c.napi_property_descriptor{
        .utf8name = "startThread",
        .name = null,
        .method = StartThread,
        .getter = null,
        .setter = null,
        .value = null,
        .attributes = c.napi_default,
        .data = @intToPtr(
            ?*anyopaque,
            @ptrToInt(&addon_data[0]))
    };

    // Decorate exports with the above-defined properties.
    status = c.napi_define_properties(env, exports, 1, &start_work);

    // Associate the addon data with the exports object, to make sure that when
    // the addon gets unloaded our data gets freed.
    status = c.napi_wrap(env,
                    exports,
                    @intToPtr(
                        ?*anyopaque,
                        @ptrToInt(&addon_data)),
                    addon_getting_unloaded,
                    null,
                    null);

    return exports;
}
