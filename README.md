# Codex Usage Tray for Windows

แอป System Tray แบบเบา ๆ สำหรับ Windows ที่อ่านเปอร์เซ็นต์ usage ล่าสุดจากไฟล์ session ของ Codex ในเครื่องแบบ **read-only** แล้ววาดเปอร์เซ็นต์ลงบนไอคอนข้างนาฬิกา

รองรับการล็อกอินด้วย ChatGPT Business workspace: ค่าที่แสดงคือ limit ที่ Codex client ส่งให้บัญชี/workspace ของผู้ใช้คนนั้น (มักระบุ `plan_type` เป็น `team`) ไม่ใช่ผลรวมของสมาชิกทุกคนใน workspace

## สิ่งที่แอปทำ

- แสดงเปอร์เซ็นต์ที่ใช้แล้วบนไอคอนและ tooltip
- แสดงช่วงเวลาและเวลา reset เมื่อคลิกขวา
- รีเฟรชอัตโนมัติทุก 60 วินาที
- เปลี่ยนสี: เขียว `< 70%`, ส้ม `< 90%`, แดง `>= 90%`
- ไม่อ่าน `auth.json`, OAuth token, browser cookie หรือ API key
- ไม่ส่งข้อมูลออกจากเครื่อง

> ข้อจำกัด: ChatGPT subscription/Codex quota ไม่มี public API สำหรับผู้ใช้ทั่วไปที่เอกสาร OpenAI รับรอง แอปนี้จึงอ่าน `rate_limits` event ที่ Codex client บันทึกไว้ใน `%USERPROFILE%\.codex\sessions`. รูปแบบไฟล์เป็น implementation detail และอาจเปลี่ยนใน Codex รุ่นถัดไป

## ติดตั้ง

ต้องมี Windows 10/11 และ Windows PowerShell 5.1 (มีมากับ Windows)

1. คลิกขวา `Install.ps1` แล้วเลือก **Run with PowerShell** หรือเปิด PowerShell ในโฟลเดอร์นี้แล้วรัน:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
   ```

2. แอปจะถูกคัดลอกไปที่ `%LOCALAPPDATA%\CodexUsageTray` และเปิดทันที
3. หากไอคอนอยู่ใต้ `^` ให้ลากออกมาวางข้างนาฬิกา

ตัวติดตั้งสร้าง shortcut ใน Startup ของผู้ใช้ปัจจุบัน ไม่ต้องใช้สิทธิ์ Administrator

ถอนการติดตั้ง:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1
```

## ใช้งานระหว่างพัฒนา

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\CodexUsageTray.ps1
```

ทดสอบ parser โดยไม่เปิด UI:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Parser.Tests.ps1
```

## โครงสร้าง

```text
CodexUsageTray/
  src/CodexUsageTray.ps1   แอป tray และ parser
  tests/Parser.Tests.ps1   smoke tests ด้วยข้อมูลจำลอง
  Install.ps1              ติดตั้งต่อผู้ใช้ + Startup
  Uninstall.ps1            ถอนการติดตั้ง
  LICENSE                  MIT
```

## ความปลอดภัยและช่องทางข้อมูล

Provider เริ่มต้นค้นหาเฉพาะไฟล์ `*.jsonl` ล่าสุดใต้ `%CODEX_HOME%\sessions` หรือ `%USERPROFILE%\.codex\sessions` และ parse เฉพาะ object ที่มี `payload.type = token_count` กับ `payload.rate_limits`. เนื้อหา prompt/response ไม่ถูกนำมาเก็บหรือแสดง

หากต้องการเพิ่ม **OpenAI API usage** ให้ทำเป็น provider แยก เพราะไม่ใช่โควตา ChatGPT/Codex subscription: เรียก Organization Usage/Costs API ด้วย Admin API key และเก็บ key ใน Windows Credential Manager หรือ DPAPI; ห้ามใส่ key ใน source/config/log. API usage ให้จำนวน token/ค่าใช้จ่าย แต่การแปลงเป็น “เปอร์เซ็นต์” ต้องมีงบประมาณที่ผู้ใช้กำหนดเอง

สำหรับเจ้าของ/แอดมิน ChatGPT Business, Compliance API สามารถใช้ทำ audit กิจกรรม Codex ระดับ workspace ได้ตามสิทธิ์และการตั้งค่าของ workspace แต่ไม่ใช่ API สำหรับอ่านเปอร์เซ็นต์โควตาคงเหลือแบบเดียวกับหน้า Codex Usage ดังนั้นแอปเวอร์ชันนี้ไม่ขอหรือเก็บ admin credential

## Troubleshooting

- ขึ้น `No Codex usage data`: เปิด Codex แล้วส่งงานหนึ่งครั้ง จากนั้นกด **Refresh now**
- path ไม่ตรง: ตั้ง environment variable `CODEX_HOME` ให้ชี้โฟลเดอร์ Codex แล้วเปิดแอปใหม่
- ไอคอนไม่หายหลังปิดผิดปกติ: เลื่อนเมาส์ผ่านตำแหน่งเดิม Windows จะล้างไอคอนค้าง
