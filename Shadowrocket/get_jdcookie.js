/*************************
初次使用时, app配置文件添加脚本配置, 并启用Mitm后:
Safari浏览器打开登录 https://home.m.jd.com/myJd/newhome.action 点击"我的"页面

[Script]
get_jdcookie = type=http-request,script-path=https://raw.githubusercontent.com/nie11kun/config-rules/master/Shadowrocket/get_jdcookie.js,pattern=^https?://api\.m\.jd\.com/client\.action\?functionId=GetJDUserInfoUnion,max-size=131072,timeout=10,enable=true

[mitm]
hostname = api.m.jd.com
*************************/

const GetCookie = () => {
    const req = $request;
    if (req.method != 'OPTIONS' && req.headers) {
        const CV = (req.headers['Cookie'] || req.headers['cookie'] || '');
        const ckItems = CV.match(/(pt_key|pt_pin)=.+?;/g);
        notify(`cookie`, `successful get jd cookie`, `${ckItems}`);
    } else if (!req.headers) {
        throw new Error("error found");
    }
}

const notify = (title, subtitle, message) => {
    $notification.post(title, subtitle, message, undefined)
}

GetCookie();
