"use strict";(()=>{var d=`
:host { all: initial; display: block; }
* { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Arial, sans-serif; }
.pb-input { width: 100%; padding: 10px 14px; font-size: 15px; color: #111827; background: #fff; border: 1px solid #d1d5db; border-radius: 8px; outline: none; }
.pb-input:focus { border-color: #4f46e5; box-shadow: 0 0 0 2px rgba(79,70,229,.15); }
.pb-backdrop { position: fixed; inset: 0; background: rgba(17,24,39,.45); z-index: 2147483000; display: flex; align-items: flex-start; justify-content: center; padding: 8vh 16px 16px; }
.pb-panel { width: 100%; max-width: 640px; background: #fff; border-radius: 12px; box-shadow: 0 20px 50px rgba(0,0,0,.25); display: flex; flex-direction: column; max-height: 80vh; overflow: hidden; }
.pb-panel-input { padding: 14px 16px; font-size: 16px; border: none; border-bottom: 1px solid #e5e7eb; outline: none; color: #111827; }
.pb-results { overflow-y: auto; }
.pb-card { display: flex; align-items: center; gap: 12px; padding: 12px 16px; border-bottom: 1px solid #f3f4f6; color: inherit; text-decoration: none; }
a.pb-card { cursor: pointer; }
.pb-card.pb-selected, .pb-card:hover { background: #eef2ff; }
.pb-thumb { width: 48px; height: 48px; border-radius: 6px; object-fit: cover; background: #f3f4f6; flex: none; }
.pb-text { min-width: 0; }
.pb-title { font-size: 14px; font-weight: 600; color: #111827; }
.pb-desc { font-size: 12px; color: #6b7280; margin-top: 2px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.pb-price { margin-left: auto; font-size: 14px; font-weight: 600; color: #4f46e5; white-space: nowrap; }
.pb-empty { padding: 24px 16px; text-align: center; font-size: 14px; color: #6b7280; }
.pb-footer { padding: 8px 16px; font-size: 11px; color: #9ca3af; text-align: right; border-top: 1px solid #f3f4f6; }
.pb-footer a { color: #6b7280; text-decoration: none; }
`;function c(e,t){let o=document.createElement("input");o.className="pb-input",o.type="search",o.placeholder="Search products\u2026",e.appendChild(o)}(()=>{let e=document.currentScript;if(!e)return;let t=e.dataset.key||"";if(!t){console.warn("[PolarBear] missing data-key attribute on the widget script tag");return}let o=e.dataset.api||new URL(e.src).origin,n=e.dataset.container||"#polarbear-search",r=()=>{let i=document.querySelector(n);if(!i){console.warn(`[PolarBear] container "${n}" not found \u2014 widget not mounted`);return}let a=i.attachShadow({mode:"open"}),p=document.createElement("style");p.textContent=d,a.appendChild(p),c(a,{api:o,key:t})};document.readyState==="loading"?document.addEventListener("DOMContentLoaded",r):r()})();})();
