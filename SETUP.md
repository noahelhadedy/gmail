<div dir="rtl">

# تجهيز Google Cloud للأبلكيشن

الأبلكيشن محتاج "Client ID" من Google عشان يقدر يدخل على الجيميل بتاعك. ده بيتعمل مرة واحدة بس، وبياخد حوالي ١٠ دقايق.

## ١. اعمل بروجكت

1. افتح [console.cloud.google.com](https://console.cloud.google.com) وانت داخل بـ **noohelhadedy@gmail.com**.
2. من فوق، دوس على اسم البروجكت ← **New Project**.
3. سميه مثلا `Gmail Menu Bar` ودوس **Create**، وبعدين اختاره.

## ٢. شغّل Gmail API

1. من القايمة: **APIs & Services ← Library**.
2. دوّر على **Gmail API** ودوس **Enable**.

## ٣. شاشة الموافقة (OAuth consent screen)

1. **APIs & Services ← OAuth consent screen** (ممكن تلاقيها باسم **Google Auth Platform ← Branding**).
2. **User type = External** ← Create.
3. اكتب اسم الأبلكيشن (`Gmail Menu Bar`) وإيميلك في الخانات المطلوبة، والباقي سيبه فاضي.
4. في **Data access / Scopes** زوّد الـ scope ده:
   `https://www.googleapis.com/auth/gmail.modify`
   (ده اللي بيخلي زرار "Mark as read" يشتغل).
5. في **Audience** دوس **Publish app** عشان الحالة تبقى **In production**.
   - ده مهم: لو سبتها **Testing**، جوجل بيبوّظ الدخول كل ٧ أيام وهتضطر تعمل Sign in تاني.
   - مش محتاج تعمل verification. أول مرة تعمل Sign in هيظهرلك "Google hasn't verified this app"، دوس **Advanced ← Go to Gmail Menu Bar (unsafe)**. ده عادي لأن الأبلكيشن بتاعك انت.

## ٤. اعمل الـ Client ID

1. **APIs & Services ← Credentials ← Create Credentials ← OAuth client ID**.
2. **Application type = Desktop app**، والاسم أي حاجة.
3. هيطلعلك **Client ID** (آخره `.apps.googleusercontent.com`) و **Client Secret** (أوله `GOCSPX-`). سيب الصفحة مفتوحة.

## ٥. احفظهم في الـ Keychain (مش في الكود)

افتح Terminal واكتب السطرين دول، كل واحد هيفتحلك خانة مخفية تلزق فيها القيمة:

```bash
~/noah-brain/bin/save-secret gmail-menubar-client-id "Gmail OAuth Client ID"
~/noah-brain/bin/save-secret gmail-menubar-client-secret "Gmail OAuth Client Secret"
```

## ٦. ابني الأبلكيشن وشغّله

```bash
cd ~/Documents/gmail-menubar
./scripts/build.sh
xattr -dr com.apple.quarantine Gmail.app
open Gmail.app
```

`build.sh` بيقرا القيم من الـ Keychain لوحده، ومفيش حاجة منهم بتتكتب في الريبو.

بعد كده: أيقونة الجواب في المنيو بار ← **Add Account** ← اختار الحساب في المتصفح. كرر نفس الخطوة لكل حساب (الشخصي، hello@djectstudio.com، noah@djectstudio.com، حسابات الشغل).

## حسابات الشغل (Google Workspace)

حسابات الشركات ممكن الأدمن يكون قافل الأبلكيشنز اللي مش verified. لو ظهرلك "This app is blocked" أو "Access blocked: admin":

- اطلب من الأدمن يروح **Admin console ← Security ← Access and data control ← API controls ← Manage Third-Party App Access** ويضيف الأبلكيشن بالـ Client ID بتاعك ويخليه **Trusted**.
- لحسابات djectstudio.com انت الأدمن، فتقدر تعملها بنفسك من نفس المكان.

## لو حاجة باظت

- **Sign in again** بيظهر جنب الحساب لو الدخول اتلغى. دوس عليه واختار نفس الحساب.
- لشيل حساب: Settings ← جنب الحساب ← علامة الـ (−).

</div>
