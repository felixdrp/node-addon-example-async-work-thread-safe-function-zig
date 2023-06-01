// How to multiple async calls from native to javascript
const example = require('./dist/lib.node');

// Call the function "startThread" which the native bindings library exposes.
// The function accepts a callback which it will call from the worker thread and
// into which it will pass prime numbers. This callback simply prints them out.
example.startThread((thePrime) =>
  console.log("Received prime from secondary thread: " + thePrime));