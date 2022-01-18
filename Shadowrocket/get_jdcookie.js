/*************************
初次使用时, app配置文件添加脚本配置, 并启用Mitm后:
Safari浏览器打开登录 https://home.m.jd.com/myJd/newhome.action 点击"我的"页面

[mitm]
hostname = api.m.jd.com
*************************/

GetCookie();

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
