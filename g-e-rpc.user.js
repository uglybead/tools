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

function SetIdTxtFunc(txt) {
  console.log("Called a SetIdTxtFunc");
  $("#dler").text("[ " + txt + " ]"); 
}

function HandleResponse(resp) {
  console.log("Got response");
  console.log(resp);
  resp_lc = resp.toLowerCase();
  if (resp_lc.startsWith("success")) {
    SetIdTxtFunc("✓");
  }
  if (resp_lc.startsWith("fail")) {
    SetIdTxtFunc("f"); 
  }
}

function MakeRpc_NonGm(url) {
  console.log("MakeRpc_NonGm clicked with: " + url);
  var requrl = "http://localhost:26469/?addr=" + encodeURIComponent(url);
  console.log("Request url:" + requrl);
  $.ajax({
    url: requrl,
    method: "GET",
    timeout: 500,
    error: function(x) { console.log("hi"); SetIdTxtFunc("e"); },
    success: function(x) { console.log("hi"); HandleResponse(x); },
  });
  
  console.log("done");
}

function RequestRpc(url) {
  MakeRpc_NonGm(url);
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
  $(target_id).after("<a id='dler'></a>");
  SetIdTxtFunc("x");
  $("#dler").click(function() {
    RequestRpc(here);
  });
}

console.log("Adding event listeners");
window.addEventListener("load", addDlLink, false);

