//
//  TongfangKbd.kext
//  MECHREVO / Uniwill (Tongfang) keyboard backlight via ACPI ECRR/ECRW
//
//  诊断方式：把寄存器快照写入 IORegistry 属性（IOLog 在本机不进 unified log）
//
//  自动阶段：
//    TFKBD-A : 启动后 5 秒的快照
//    TFKBD-B : 启动后 20 秒的快照（判断是否被系统改过）
//    TFKBD-C : 自动写入后 1.5 秒的快照（mode != 0 时才写）
//
//  运行时控制（sysctl，无需重启）：
//    kern.tfkbd_reg  目标寄存器地址（默认 0x078C）
//    kern.tfkbd_val  要写入的值
//    kern.tfkbd_cmd  命令：
//                      1 = 写 gReg <- gVal，然后快照到 TFKBD-D
//                      2 = 读 gReg，结果放 TFKBD-R
//                      3 = 完整应用：RGB/默认电平 = gLevel，0x078C = gVal，再触发 0x0767=0x20
//                      4 = 打开 China Mode（0x0766 |= 0x20）
//                      5 = 只快照到 TFKBD-D
//                      6 = 关闭 China Mode（0x0766 &= ~0x20）
//    kern.tfkbd_level  cmd=3 时使用的前景色电平 0..50
//

#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/IOTimerEventSource.h>
#include <IOKit/acpi/IOACPIPlatformDevice.h>
#include <pexpert/pexpert.h>
#include <libkern/libkern.h>
#include <sys/sysctl.h>

#define TF_TAG "TFKBD: "

//  EC 寄存器（Uniwill/Tongfang）
#define REG_PROJECT_ID      0x0740
#define REG_SUPPORT_1       0x0765
#define REG_SUPPORT_2       0x0766
#define REG_TRIGGER         0x0767
#define REG_STATUS          0x0768
#define REG_R               0x0769
#define REG_G               0x076A
#define REG_B               0x076B
#define REG_DEF_R           0x076C
#define REG_DEF_G           0x076D
#define REG_DEF_B           0x076E
#define REG_KBD_STATUS      0x078C

#define TRIGGER_APPLY       0x20
#define CHINA_MODE_BIT      0x20

class TongfangKbd : public IOService
{
    OSDeclareDefaultStructors(TongfangKbd)

public:
    virtual bool start(IOService *provider) override;
    virtual void stop(IOService *provider) override;
    virtual void free() override;

    void onTimer();
    void runCommand(int cmd);
    void appendHistory(const char *msg);

    IOReturn readReg(UInt16 reg, UInt8 *out);
    IOReturn writeReg(UInt16 reg, UInt8 val);

private:
    void snapshot(const char *key);
    void applyLevels(UInt8 level, int mode);

    IOACPIPlatformDevice *fDev;
    IOTimerEventSource   *fTimer;
    int                   fPhase;
    int                   fLevel;
    int                   fMode;
    bool                  fDone;
};

OSDefineMetaClassAndStructors(TongfangKbd, IOService)

// ---------------------------------------------------------------------------
//  sysctl 全局状态
// ---------------------------------------------------------------------------
static int             gReg   = REG_KBD_STATUS;
static int             gVal   = 0x70;
static int             gLevel = 50;
static int             gAutoStatus = -1;   // boot-arg tfkbdstatus=0x??，-1 表示未指定
static int             gAutoChina  = 0;    // boot-arg tfkbdchina=1
static TongfangKbd    *gKbd   = NULL;

static void tfkbd_register_sysctl(void);
static void tfkbd_unregister_sysctl(void);

IOReturn TongfangKbd::readReg(UInt16 reg, UInt8 *out)
{
    OSObject *param = OSNumber::withNumber((unsigned long long)reg, 32);
    if (!param) {
        return kIOReturnNoMemory;
    }

    UInt32 value = 0;
    IOReturn kr = fDev->evaluateInteger("ECRR", &value, &param, 1, 0);
    param->release();

    if (kr == kIOReturnSuccess) {
        *out = (UInt8)(value & 0xFF);
    }
    return kr;
}

IOReturn TongfangKbd::writeReg(UInt16 reg, UInt8 val)
{
    OSObject *params[2];
    params[0] = OSNumber::withNumber((unsigned long long)reg, 32);
    params[1] = OSNumber::withNumber((unsigned long long)val, 32);
    if (!params[0] || !params[1]) {
        if (params[0]) params[0]->release();
        if (params[1]) params[1]->release();
        return kIOReturnNoMemory;
    }

    IOReturn kr = fDev->evaluateObject("ECRW", NULL, params, 2, 0);
    params[0]->release();
    params[1]->release();

    IOSleep(6);
    return kr;
}

void TongfangKbd::snapshot(const char *key)
{
    const struct { UInt16 reg; const char *name; } regs[] = {
        { REG_PROJECT_ID, "40"   },
        { REG_SUPPORT_1,  "65"   },
        { REG_SUPPORT_2,  "66"   },
        { REG_TRIGGER,    "67"   },
        { REG_STATUS,     "68"   },
        { REG_R,          "69"   },
        { REG_G,          "6A"   },
        { REG_B,          "6B"   },
        { REG_DEF_R,      "6C"   },
        { REG_DEF_G,      "6D"   },
        { REG_DEF_B,      "6E"   },
        { REG_KBD_STATUS, "8C"   },
    };

    char buf[256];
    int  n = 0;
    buf[0] = 0;

    for (unsigned i = 0; i < sizeof(regs) / sizeof(regs[0]); i++) {
        UInt8 v = 0;
        IOReturn kr = readReg(regs[i].reg, &v);
        if (kr != kIOReturnSuccess) {
            n += snprintf(buf + n, (size_t)(sizeof(buf) - (size_t)n), "%s=XX ", regs[i].name);
        } else {
            n += snprintf(buf + n, (size_t)(sizeof(buf) - (size_t)n), "%s=%02X ", regs[i].name, v);
        }
        if (n >= (int)sizeof(buf) - 16) {
            break;
        }
    }

    setProperty(key, buf);
    appendHistory(buf);
    IOLog(TF_TAG "%s: %s\n", key, buf);
}

void TongfangKbd::appendHistory(const char *msg)
{
    OSString *old = OSDynamicCast(OSString, getProperty("TFKBD-HIST"));
    char buf[1024];
    buf[0] = 0;

    if (old) {
        strlcpy(buf, old->getCStringNoCopy(), sizeof(buf));
    }
    size_t len = strlen(buf);
    if (len > 600) {
        // 只保留后半段，防止无限增长
        memmove(buf, buf + (len - 600), 601);
        len = strlen(buf);
    }
    snprintf(buf + len, sizeof(buf) - len, "| %s", msg);

    setProperty("TFKBD-HIST", buf);
}

void TongfangKbd::applyLevels(UInt8 lvl, int mode)
{
    char msg[64];

    writeReg(REG_R, lvl);
    writeReg(REG_G, lvl);
    writeReg(REG_B, lvl);
    writeReg(REG_DEF_R, lvl);
    writeReg(REG_DEF_G, lvl);
    writeReg(REG_DEF_B, lvl);

    if (gAutoStatus >= 0) {
        writeReg(REG_KBD_STATUS, (UInt8)gAutoStatus);
    } else if (mode == 1) {
        writeReg(REG_KBD_STATUS, 0x01);
    } else if (mode >= 2) {
        writeReg(REG_KBD_STATUS, 0x70);
    }
    if (mode == 3 || gAutoChina) {
        UInt8 v = 0;
        if (readReg(REG_SUPPORT_2, &v) == kIOReturnSuccess) {
            writeReg(REG_SUPPORT_2, (UInt8)(v | CHINA_MODE_BIT));
        }
    }

    writeReg(REG_TRIGGER, TRIGGER_APPLY);

    snprintf(msg, sizeof(msg), "auto mode=%d level=%u", mode, (unsigned)lvl);
    appendHistory(msg);
}

void TongfangKbd::runCommand(int cmd)
{
    char msg[96];

    switch (cmd) {
    case 1: {
        IOReturn kr = writeReg((UInt16)gReg, (UInt8)gVal);
        snprintf(msg, sizeof(msg), "W %04X<-%02X kr=%d", gReg, gVal, (int)kr);
        appendHistory(msg);
        setProperty("TFKBD-Wrote", true);
        snapshot("TFKBD-D");
        break;
    }

    case 2: {
        UInt8 v = 0;
        IOReturn kr = readReg((UInt16)gReg, &v);
        if (kr == kIOReturnSuccess) {
            setProperty("TFKBD-R", (unsigned long long)v, 8);
            snprintf(msg, sizeof(msg), "R %04X=%02X", gReg, v);
        } else {
            snprintf(msg, sizeof(msg), "R %04X failed kr=%d", gReg, (int)kr);
        }
        appendHistory(msg);
        break;
    }

    case 3: {
        UInt8 lvl = (gLevel < 0) ? 0 : ((gLevel > 50) ? 50 : (UInt8)gLevel);
        UInt8 st  = (UInt8)gVal;

        writeReg(REG_R, lvl);
        writeReg(REG_G, lvl);
        writeReg(REG_B, lvl);
        writeReg(REG_DEF_R, lvl);
        writeReg(REG_DEF_G, lvl);
        writeReg(REG_DEF_B, lvl);
        writeReg(REG_KBD_STATUS, st);
        writeReg(REG_TRIGGER, TRIGGER_APPLY);

        snprintf(msg, sizeof(msg), "APPLY lvl=%u 8C=%02X", (unsigned)lvl, st);
        appendHistory(msg);
        setProperty("TFKBD-Wrote", true);
        snapshot("TFKBD-D");
        break;
    }

    case 4:
    case 6: {
        UInt8 v = 0;
        if (readReg(REG_SUPPORT_2, &v) == kIOReturnSuccess) {
            UInt8 nv = (cmd == 4) ? (UInt8)(v | CHINA_MODE_BIT)
                                  : (UInt8)(v & ~CHINA_MODE_BIT);
            writeReg(REG_SUPPORT_2, nv);
            writeReg(REG_TRIGGER, TRIGGER_APPLY);
            snprintf(msg, sizeof(msg), "CHINA 66: %02X -> %02X", v, nv);
        } else {
            snprintf(msg, sizeof(msg), "CHINA 66 read failed");
        }
        appendHistory(msg);
        snapshot("TFKBD-D");
        break;
    }

    case 5:
    default:
        snapshot("TFKBD-D");
        break;
    }
}

bool TongfangKbd::start(IOService *provider)
{
    if (!IOService::start(provider)) {
        return false;
    }

    fDev = OSDynamicCast(IOACPIPlatformDevice, provider);
    if (!fDev) {
        IOLog(TF_TAG "provider is not IOACPIPlatformDevice\n");
        return false;
    }

    fPhase = 0;
    fDone  = false;
    fLevel = 50;
    fMode  = 2;          // 2 = 自动点亮：电平 50 + 0x078C=0x70（实测可用组合）

    int arg = 0;
    if (PE_parse_boot_argn("tfkbd", &arg, sizeof(arg))) {
        if (arg >= 0 && arg <= 50) {
            fLevel = arg;
        }
    }
    arg = 0;
    if (PE_parse_boot_argn("tfkbdmode", &arg, sizeof(arg))) {
        if (arg >= 0 && arg <= 3) {
            fMode = arg;
        }
    }

    arg = 0;
    if (PE_parse_boot_argn("tfkbdstatus=%x", &arg, sizeof(arg))) {
        if (arg >= 0 && arg <= 0xFF) {
            gAutoStatus = arg;
        }
    }
    arg = 0;
    if (PE_parse_boot_argn("tfkbdchina=%d", &arg, sizeof(arg))) {
        gAutoChina = (arg != 0) ? 1 : 0;
    }

    setProperty("TFKBD-AutoStatus", (unsigned long long)(gAutoStatus < 0 ? 0xFFFF : gAutoStatus), 32);
    setProperty("TFKBD-AutoChina", (unsigned long long)gAutoChina, 32);
    setProperty("TFKBD-Level", (unsigned long long)fLevel, 32);
    setProperty("TFKBD-Mode", (unsigned long long)fMode, 32);

    gLevel = fLevel;
    gKbd   = this;

    tfkbd_register_sysctl();

    fTimer = IOTimerEventSource::timerEventSource(this,
        OSMemberFunctionCast(IOTimerEventSource::Action, this, &TongfangKbd::onTimer));
    if (!fTimer) {
        return false;
    }

    IOWorkLoop *wl = getWorkLoop();
    if (!wl || wl->addEventSource(fTimer) != kIOReturnSuccess) {
        fTimer->release();
        fTimer = NULL;
        return false;
    }

    fTimer->setTimeoutMS(5000);
    registerService();
    return true;
}

void TongfangKbd::free()
{
    if (gKbd == this) {
        gKbd = NULL;
    }
    if (fTimer) {
        fTimer->release();
        fTimer = NULL;
    }
    IOService::free();
}

void TongfangKbd::stop(IOService *provider)
{
    tfkbd_unregister_sysctl();
    if (gKbd == this) {
        gKbd = NULL;
    }
    if (fTimer) {
        fTimer->cancelTimeout();
        IOWorkLoop *wl = getWorkLoop();
        if (wl) {
            wl->removeEventSource(fTimer);
        }
        fTimer->release();
        fTimer = NULL;
    }
    IOService::stop(provider);
}

void TongfangKbd::onTimer()
{
    if (fDone) {
        return;
    }

    switch (fPhase) {
    case 0:
        snapshot("TFKBD-A");
        fPhase = 1;
        fTimer->setTimeoutMS(15000);
        break;

    case 1:
        snapshot("TFKBD-B");
        if (fMode != 0) {
            applyLevels((UInt8)fLevel, fMode);
            setProperty("TFKBD-Wrote", true);
        }
        fPhase = 2;
        fTimer->setTimeoutMS(20000);
        break;

    case 2:
        // 40 秒再补一次：防止 EC 周期任务在开机早期把状态清掉
        if (fMode != 0) {
            applyLevels((UInt8)fLevel, fMode);
        }
        snapshot("TFKBD-C");
        fPhase = 3;
        fTimer->setTimeoutMS(2000);
        break;

    case 3:
        snapshot("TFKBD-E");
        fDone = true;
        break;

    default:
        fDone = true;
        break;
    }
}

// ---------------------------------------------------------------------------
//  sysctl 接口：装一次之后所有实验都不用重启
// ---------------------------------------------------------------------------
static int sysctl_tfkbd_cmd SYSCTL_HANDLER_ARGS
{
    int v   = 0;
    int err = sysctl_handle_int(oidp, &v, 0, req);
    if (err || req->newptr == 0) {
        return err;
    }
    if (gKbd) {
        gKbd->runCommand(v);
    }
    return 0;
}

SYSCTL_INT(_kern, OID_AUTO, tfkbd_reg,   CTLFLAG_RW | CTLFLAG_ANYBODY, &gReg,   0, "TFKBD target EC register");
SYSCTL_INT(_kern, OID_AUTO, tfkbd_val,   CTLFLAG_RW | CTLFLAG_ANYBODY, &gVal,   0, "TFKBD value to write");
SYSCTL_INT(_kern, OID_AUTO, tfkbd_level, CTLFLAG_RW | CTLFLAG_ANYBODY, &gLevel, 0, "TFKBD RGB level 0-50");
SYSCTL_PROC(_kern, OID_AUTO, tfkbd_cmd, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_ANYBODY,
            0, 0, sysctl_tfkbd_cmd, "I", "TFKBD command");

// ---------------------------------------------------------------------------
//  sysctl 节点：SYSCTL_* 宏只是定义了静态结构体，kext 不会被内核自动注册，
//  必须自己调 sysctl_register_oid()，否则 kern.tfkbd_* 根本不存在
// ---------------------------------------------------------------------------
// 这些结构体由上面的 SYSCTL_* 宏在同一个编译单元里定义，保持 C++ 链接
extern struct sysctl_oid sysctl__kern_tfkbd_reg;
extern struct sysctl_oid sysctl__kern_tfkbd_val;
extern struct sysctl_oid sysctl__kern_tfkbd_level;
extern struct sysctl_oid sysctl__kern_tfkbd_cmd;

void sysctl_register_oid(struct sysctl_oid *oidp);
void sysctl_unregister_oid(struct sysctl_oid *oidp);

static int  gSysctlReady = 0;

static void tfkbd_register_sysctl(void)
{
    if (gSysctlReady) {
        return;
    }
    sysctl_register_oid(&sysctl__kern_tfkbd_reg);
    sysctl_register_oid(&sysctl__kern_tfkbd_val);
    sysctl_register_oid(&sysctl__kern_tfkbd_level);
    sysctl_register_oid(&sysctl__kern_tfkbd_cmd);
    gSysctlReady = 1;
    IOLog(TF_TAG "sysctl registered\n");
}

static void tfkbd_unregister_sysctl(void)
{
    if (!gSysctlReady) {
        return;
    }
    sysctl_unregister_oid(&sysctl__kern_tfkbd_cmd);
    sysctl_unregister_oid(&sysctl__kern_tfkbd_level);
    sysctl_unregister_oid(&sysctl__kern_tfkbd_val);
    sysctl_unregister_oid(&sysctl__kern_tfkbd_reg);
    gSysctlReady = 0;
}

// ---------------------------------------------------------------------------
//  kext 入口结构：Xcode 的 kextsymboltool 会生成它，这里手工补上
// ---------------------------------------------------------------------------
#include <mach/kmod.h>

extern "C" {

kern_return_t _start(kmod_info_t *ki, void *data)
{
    return KERN_SUCCESS;
}

kern_return_t _stop(kmod_info_t *ki, void *data)
{
    return KERN_SUCCESS;
}

__attribute__((used, visibility("default")))
kmod_info_t kmod_info = {
    NULL,                    // next
    1,                       // info_version
    0xffffffff,              // id
    "com.local.tongfangkbd", // name
    "1.0.0",                 // version
    -1,                      // reference_count
    NULL,                    // reference_list
    0,                       // address
    0,                       // size
    0,                       // hdr_size
    _start,                  // start
    _stop                    // stop
};

}
