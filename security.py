:root {
  --bg: #f4f6f8;
  --card: #ffffff;
  --text: #18212b;
  --muted: #667085;
  --primary: #155eef;
  --primary-dark: #004eeb;
  --border: #d0d5dd;
  --success: #067647;
  --warning: #b54708;
  --danger: #b42318;
}
* { box-sizing: border-box; }
body { margin: 0; font-family: Arial, Helvetica, sans-serif; background: var(--bg); color: var(--text); }
a { color: var(--primary); text-decoration: none; }
a:hover { text-decoration: underline; }
header { background: #101828; color: white; padding: 14px 0; }
.container { width: min(1180px, calc(100% - 30px)); margin: 0 auto; }
.nav { display: flex; align-items: center; justify-content: space-between; gap: 18px; }
.nav-left, .nav-right { display: flex; align-items: center; gap: 14px; flex-wrap: wrap; }
.nav a { color: white; }
.brand { font-weight: 700; font-size: 18px; }
main { padding: 24px 0 50px; }
h1 { margin: 0 0 18px; font-size: 28px; }
h2 { font-size: 21px; margin: 0 0 14px; }
h3 { font-size: 17px; margin: 0 0 10px; }
.card { background: var(--card); border: 1px solid var(--border); border-radius: 12px; padding: 18px; margin-bottom: 18px; box-shadow: 0 1px 2px rgba(16,24,40,.04); }
.grid { display: grid; grid-template-columns: repeat(2, minmax(0,1fr)); gap: 16px; }
.grid-3 { display: grid; grid-template-columns: repeat(3, minmax(0,1fr)); gap: 16px; }
.grid-4 { display: grid; grid-template-columns: repeat(4, minmax(0,1fr)); gap: 16px; }
label { display: block; font-weight: 700; font-size: 13px; margin-bottom: 6px; }
input, select, textarea { width: 100%; padding: 10px 11px; border: 1px solid var(--border); border-radius: 8px; background: white; font: inherit; }
textarea { min-height: 86px; resize: vertical; }
button, .button { display: inline-block; border: 0; background: var(--primary); color: white; border-radius: 8px; padding: 10px 14px; font-weight: 700; cursor: pointer; text-decoration: none; }
button:hover, .button:hover { background: var(--primary-dark); text-decoration: none; }
.button.secondary, button.secondary { background: #344054; }
.button.success, button.success { background: var(--success); }
.button.warning, button.warning { background: var(--warning); }
.button.danger, button.danger { background: var(--danger); }
.button.light, button.light { background: #eaecf0; color: #344054; }
.actions { display: flex; gap: 9px; align-items: center; flex-wrap: wrap; }
.inline { display: inline; }
.alert { padding: 12px 14px; border-radius: 8px; margin-bottom: 18px; border: 1px solid; }
.alert-info { color: #175cd3; background: #eff8ff; border-color: #b2ddff; }
.alert-success { color: #067647; background: #ecfdf3; border-color: #abefc6; }
.alert-warning { color: #b54708; background: #fffaeb; border-color: #fedf89; }
.alert-danger { color: #b42318; background: #fef3f2; border-color: #fecdca; }
.table-wrap { overflow-x: auto; }
table { width: 100%; border-collapse: collapse; }
th, td { text-align: left; vertical-align: top; padding: 10px; border-bottom: 1px solid #eaecf0; font-size: 14px; }
th { color: #475467; background: #f9fafb; }
.badge { display: inline-block; font-size: 12px; font-weight: 700; padding: 4px 8px; border-radius: 999px; background: #eaecf0; }
.badge-draft { color: #344054; background: #eaecf0; }
.badge-issued { color: #175cd3; background: #eff8ff; }
.badge-in_transit { color: #b54708; background: #fffaeb; }
.badge-delivered { color: #067647; background: #ecfdf3; }
.badge-cancelled { color: #b42318; background: #fef3f2; }
.meta { color: var(--muted); font-size: 13px; }
.kpi { font-size: 28px; font-weight: 700; }
code.url { display: block; overflow-wrap: anywhere; background: #f2f4f7; padding: 9px; border-radius: 7px; font-size: 12px; }
fieldset { border: 1px solid var(--border); border-radius: 10px; padding: 14px; margin: 0 0 16px; }
legend { font-weight: 700; padding: 0 8px; }
.login-card { max-width: 430px; margin: 60px auto; }
.mobile-shell { max-width: 700px; margin: 0 auto; }
footer { color: var(--muted); font-size: 12px; padding: 20px 0; }
@media (max-width: 850px) {
  .grid, .grid-3, .grid-4 { grid-template-columns: 1fr; }
  .nav { align-items: flex-start; }
  h1 { font-size: 24px; }
}
