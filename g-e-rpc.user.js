// ==UserScript==
// @name        g-e-rpc
// @namespace   blah
// @include     http://g.e-hentai.org/g/*/*
// @include	http://thedoujin.com/index.php/categories/*
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

function getTargetId(url) {
  var matchers = [["http://g.e-hentai.org/g", "#gn"],
		  ["http://thedoujin.com/index.php/categories/", "#add-favorite"]];
  for(var i = 0; i < matchers.length; ++i) {
    if (url.substring(0, matchers[i][0].length) == matchers[i][0]) {
      return matchers[i][1];
    }
  }
  return null;
}

function addDlLink() {
  console.log("ran addDlLink");
  var here = window.location.href;
  var target_id = getTargetId(here);
  if (target_id == null) {
    console.log("No known target_id for url");
    return; 
  }
  $(target_id).after("<a id='dler'>[ x ]</a>");
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
