// ==UserScript==
// @name        g-e-rpc
// @namespace   blah
// @include     http://g.e-hentai.org/g/*/*
// @version     1
// @grant       GM_xmlhttpRequest
// @require     https://ajax.googleapis.com/ajax/libs/jquery/2.1.3/jquery.min.js
// ==/UserScript==

console.log("top of script");

function MakeRpc(url) {
  console.log("MakeRpc clicked with: " + url);

  GM_xmlhttpRequest({
    method: "POST",
    url: "http://localhost:26469/?addr=" + encodeURIComponent(url),
    timeout: 5000,

  });
  console.log("done");
  console.log(ret);
}

function RequestRpc(url) {
  var request_txt = JSON.stringify(['g-e-req-addr', url]);
  window.postMessage(request_txt, "*");
}

function addDlLink() {
  console.log("ran addDlLink");
  var here = window.location.href;
  $("#gn").after("<a id='dler'>[ x ]</a>");
  $("#dler").click(function() {
    RequestRpc(here);
  });
}

function listenForRequest(event) {
  var message;
  try {
    message = JSON.parse(event.data);
  } catch (err) {
    return;
  }
  console.log("Got request: " + message);
  if (message[0] != "g-e-req-addr") {
    console.log("Not for us.");
    return;
  }
  if (message.length < 2) {
    console.log("Message too missing addr?"); 
  }
  MakeRpc(message[1]);
}

console.log("Adding event listeners");
window.addEventListener("load", addDlLink, false);
window.addEventListener("message", listenForRequest, false);
