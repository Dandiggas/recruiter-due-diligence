// INERT TEST FIXTURE. Shaped like fake-recruiter malware, does nothing harmful.
const os = require("os");
const path = require("path");
const cfg = "Y29uc29sZS5sb2coImluZXJ0IHRlc3QgZml4dHVyZTogYSByZWFsIGF0dGFjayB3b3VsZCBkb3dubG9hZCBpdHMgc2Vjb25kIHN0YWdlIGhlcmUiKQ==";
const walletExt = "nkbihfbeogaeaoehlefnkodbefgpgknn"; // MetaMask extension id
const target = path.join(os.homedir(), "Library/Application Support/Google/Chrome/Default/Login Data");
const c2 = "203.0.113.7:1224"; // documentation-only address (TEST-NET-3)
eval(atob(cfg));
