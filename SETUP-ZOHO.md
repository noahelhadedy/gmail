# إعداد Zoho Mail في Gmail menubar

الهدف: ايميل `hello@designbookmark.com` (مستضاف على Zoho مش Gmail) يظهر في نفس التطبيق جنب حسابات Gmail.

## اللي اتعمل في الكود وليه

- اخترنا **Zoho Mail REST API مع OAuth 2.0** (مش IMAP).
- السبب: حسابك على خطة **Free** (`imapAccessEnabled: false` في بيانات الحساب). Zoho بتقفل IMAP و POP على الخطة المجانية، فمفيش app password ينفع. الـ API شغال على الخطة المجانية (اتأكدنا من الحساب نفسه).
- الـ Data center: **zoho.com (US)**. الـ MX بتاع designbookmark.com هو `mx.zoho.com`، يعني الدومينات هي `accounts.zoho.com` و `mail.zoho.com`.
- مهم: صندوق الوارد الحقيقي هو `noah@designbookmark.com` و `hello@designbookmark.com` هو alias بيوصّل لنفس الصندوق (كمان `support@`). التطبيق هيعرض الحساب باسم `hello@designbookmark.com` لو سجلت بالـ hint بتاعه، والعدد هيبقى عدد الوارد كله (كل الـ aliases).

## الخطوات (مرة واحدة)

1. افتح https://api-console.zoho.com وسجل دخول بـ **noah@designbookmark.com** (هو الـ super admin بتاع الدومين).
2. اضغط **Add Client** (أو Get Started).
3. اختار نوع الـ client: **Server-based Applications**.
   - ده اللي بيقبل redirect على `http://127.0.0.1` ومعاه Client Secret، والتطبيق بيستخدم الاتنين (وبيبعت PKCE كمان).
   - لو الـ Console رفض الـ redirect بتاع http في النوع ده، جرب **Mobile-based Applications** بنفس الـ redirect. الكود بيشتغل مع الاتنين.
4. املا:
   - **Client Name**: `Gmail menubar`
   - **Homepage URL**: `http://127.0.0.1:53682/`
   - **Authorized Redirect URIs**: بالظبط `http://127.0.0.1:53682/` (بالسلاش في الآخر، ومن غير أي حاجة زيادة. لازم تتطابق حرف بحرف).
5. اضغط **Create**. هتلاقي **Client ID** و **Client Secret** في تاب Client Secret.
6. مفيش scopes تختارها في الـ Console. التطبيق بيطلبها وقت الموافقة:
   `ZohoMail.accounts.READ`, `ZohoMail.folders.READ`, `ZohoMail.messages.READ`, `ZohoMail.messages.UPDATE`
7. احفظ القيمتين في الـ Keychain (مش في الريبو أبدا):
   ```bash
   ~/noah-brain/bin/save-secret zoho-menubar-client-id "Zoho Client ID"
   ~/noah-brain/bin/save-secret zoho-menubar-client-secret "Zoho Client Secret"
   ```
8. ابني التطبيق وثبّته:
   ```bash
   cd ~/Documents/gmail-menubar
   ./scripts/build.sh
   pkill -f "/Applications/Gmail.app/Contents/MacOS/Gmail"
   ditto Gmail.app /Applications/Gmail.app && xattr -dr com.apple.quarantine /Applications/Gmail.app
   /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Gmail.app
   open /Applications/Gmail.app
   ```
   لو الـ build.sh ما لقاش القيمتين بيكمل من غير Zoho ويطبع تنبيه، و"Add Zoho Account" بتبقى مخفية.
9. ضيف الحساب:
   ```bash
   open "gmailmenubar://add-zoho-account?login_hint=hello@designbookmark.com"
   cat ~/Library/Application\ Support/Gmail/pending-auth-url.txt
   ```
   افتح اللينك اللي في الملف في Chrome، سجل بـ noah@designbookmark.com، واضغط **Accept**. Zoho هتحوّل على `127.0.0.1:53682` والتطبيق يكمل لوحده (الملف بيتمسح بعد النجاح).
   أو من التطبيق نفسه: Settings، **Add Zoho Account…** (أو زرار الشخص + في الـ popover).
10. اتأكد:
    ```bash
    open "gmailmenubar://status"
    cat ~/Library/Application\ Support/Gmail/accounts-status.json
    ```
    لازم تلاقي `"provider": "zoho"` و `"state": "ok"`.

## ملاحظات

- لو اتفتح البورت 53682 في برنامج تاني، تسجيل الدخول هيفشل برسالة `port 53682 unavailable`. اقفل البرنامج وجرب تاني.
- لو Zoho رجعت `invalid_redirect_uri`: الـ Redirect URI في الـ Console مش مطابق حرف بحرف.
- بعد ما تضيف الحساب مش محتاج Client Secret تاني غير وقت تجديد الـ token، وهو متخزن جوه التطبيق وقت الـ build.
- عدد الـ unread بيتحسب لحد 200 رسالة (حد الـ API في الطلب الواحد)، وبعدها بيفضل 200.
- الخطة المجانية: الـ API شغال، IMAP و POP لأ. لو رقيت لخطة مدفوعة IMAP هيبقى متاح، بس مش محتاجينه.
- لينك فتح الرسالة في المتصفح: `https://mail.zoho.com/zm/#mail/folder/inbox/p/<messageId>` (الصيغة دي مش موثقة رسميا من Zoho. لو فتحت على الـ inbox بس، ابعتلي).
