//+------------------------------------------------------------------+
//| KimieStatusReporter.mq5                                          |
//| STATUS-ONLY EA: posts account heartbeat to the Google Sheet      |
//| every N minutes. NO signal polling, NO trading, NO orders.      |
//| Safe to attach on ANY terminal / ANY account.                    |
//|                                                                  |
//| INSTALL                                                          |
//|  1. Copy to <MT5 data folder>/MQL5/Experts/, compile (F7)        |
//|  2. Tools > Options > Expert Advisors > allow WebRequest for:   |
//|     https://docs.google.com                                      |
//|  3. Drag onto ANY chart (symbol/TF irrelevant)                   |
//|  4. Fill StatusFormURL + StatusEntry (same values as main EA)    |
//|  5. Enable Algo Trading                                          |
//| Each terminal reports its own account + server, so the sheet    |
//| distinguishes every account automatically.                      |
//+------------------------------------------------------------------+
#property copyright "Kimie & Zizi"
#property version   "1.00"
#property strict

input string StatusFormURL = "https://docs.google.com/forms/d/e/1FAIpQLSfCP6f4rb8kW_DBCICbc5II7eiyPOwSCoRAJGH3aGcPoUMQmw/formResponse";
input string StatusEntry   = "entry.1119234569";
input int    StatusMinutes = 15;    // heartbeat every N minutes
input string Tag           = "";    // optional label (e.g. "vps1")

datetime g_last = 0;

//+------------------------------------------------------------------+
string UrlEncode(const string s)
{
   string out = "";
   for(int i = 0; i < StringLen(s); i++)
   {
      ushort c = StringGetCharacter(s, i);
      if((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
         || (c >= '0' && c <= '9') || c == '-' || c == '_'
         || c == '.' || c == '~' || c == '=' || c == ';')
         out += CharToString((uchar)c);
      else
         out += StringFormat("%%%02X", (int)c);
   }
   return out;
}
//+------------------------------------------------------------------+
void Post(const string payload)
{
   if(StringLen(StatusFormURL) == 0 || StringLen(StatusEntry) == 0) return;
   string body = StatusEntry + "=" + UrlEncode(payload);
   char post[];
   StringToCharArray(body, post, 0, StringLen(body), CP_ACP);
   ArrayResize(post, StringLen(body));
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   char result[];
   string resHeaders;
   ResetLastError();
   int status = WebRequest("POST", StatusFormURL, headers, 8000,
                           post, result, resHeaders);
   if(status != 200)
      Print("STATUS POST failed status=", status, " err=", GetLastError(),
            " (allowlist https://docs.google.com)");
}
//+------------------------------------------------------------------+
void Heartbeat()
{
   double bal  = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
   double fm   = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double flpl = AccountInfoDouble(ACCOUNT_PROFIT);  // whole-account floating P/L
   int    posN = PositionsTotal();
   string payload = "type=hb"
      + ";acct=" + (string)AccountInfoInteger(ACCOUNT_LOGIN)
      + ";srv=" + AccountInfoString(ACCOUNT_SERVER)
      + ";ver=reporter1.0"
      + ";bal=" + DoubleToString(bal, 2)
      + ";eq=" + DoubleToString(eq, 2)
      + ";fm=" + DoubleToString(fm, 2)
      + ";pos=" + (string)posN
      + ";flpl=" + DoubleToString(flpl, 2)
      + ";conn=" + (string)TerminalInfoInteger(TERMINAL_CONNECTED)
      + ";ping=" + (string)(TerminalInfoInteger(TERMINAL_PING_LAST) / 1000)
      + (StringLen(Tag) > 0 ? ";tag=" + Tag : "")
      + ";tm=" + TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS);
   Post(payload);
}
//+------------------------------------------------------------------+
int OnInit()
{
   EventSetTimer(60);   // check every minute, post every StatusMinutes
   Heartbeat();        // immediate first report
   Print("KimieStatusReporter started - account ",
         AccountInfoInteger(ACCOUNT_LOGIN),
         " @ ", AccountInfoString(ACCOUNT_SERVER));
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason) { EventKillTimer(); }
void OnTimer()
{
   if(TimeGMT() - g_last >= StatusMinutes * 60)
   {
      g_last = TimeGMT();
      Heartbeat();
   }
}
//+------------------------------------------------------------------+
