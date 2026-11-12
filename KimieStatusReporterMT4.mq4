//+------------------------------------------------------------------+
//| KimieStatusReporterMT4.mq4                                       |
//| STATUS-ONLY EA for MetaTrader 4 terminals.                       |
//| Posts account heartbeat to the Google Sheet every N minutes.     |
//| NO trading, NO orders, NO signal reading. Safe on any account.    |
//|                                                                  |
//| INSTALL (MT4)                                                     |
//|  1. Copy to <MT4 data folder>/MQL4/Experts/, compile in MetaEditor|
//|  2. Tools > Options > Expert Advisors:                           |
//|     - Allow WebRequest for listed URL: https://docs.google.com    |
//|     - Allow automated trading (untuk timer EA - tiada trade)      |
//|  3. Drag onto ANY chart, enable AutoTrading                      |
//+------------------------------------------------------------------+
#property copyright "Kimie & Zizi"
#property version   "1.00"
#property strict

input string StatusFormURL = "https://docs.google.com/forms/d/e/1FAIpQLSfCP6f4rb8kW_DBCICbc5II7eiyPOwSCoRAJGH3aGcPoUMQmw/formResponse";
input string StatusEntry   = "entry.1119234569";
input int    StatusMinutes = 15;    // heartbeat every N minutes
input string Tag           = "mt4";

datetime g_last = 0;

//+------------------------------------------------------------------+
string UrlEncode(string s)
{
   string out = "";
   for(int i = 0; i < StringLen(s); i++)
   {
      int c = StringGetChar(s, i);
      if((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
         || (c >= '0' && c <= '9') || c == '-' || c == '_'
         || c == '.' || c == '~' || c == '=' || c == ';')
         out = out + CharToString(c);
      else
         out = out + StringFormat("%%%02X", c);
   }
   return out;
}
//+------------------------------------------------------------------+
void Post(string payload)
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
            " (check https://docs.google.com in Tools>Options>Expert Advisors)");
}
//+------------------------------------------------------------------+
void Heartbeat()
{
   int posN = 0;
   for(int i = 0; i < OrdersTotal(); i++)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         if(OrderType() == OP_BUY || OrderType() == OP_SELL) posN++;
   }
   string payload = "type=hb"
      + ";acct=" + IntegerToString(AccountNumber())
      + ";srv=" + AccountServer()
      + ";ver=reporter-mt4.1"
      + ";bal=" + DoubleToString(AccountBalance(), 2)
      + ";eq=" + DoubleToString(AccountEquity(), 2)
      + ";fm=" + DoubleToString(AccountFreeMargin(), 2)
      + ";pos=" + IntegerToString(posN)
      + ";flpl=" + DoubleToString(AccountProfit(), 2)
      + ";conn=" + (IsConnected() ? "1" : "0")
      + ";ping=0"
      + (StringLen(Tag) > 0 ? ";tag=" + Tag : "")
      + ";tm=" + TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS);
   Post(payload);
}
//+------------------------------------------------------------------+
int OnInit()
{
   EventSetTimer(60);
   Heartbeat();
   Print("KimieStatusReporterMT4 started - account ",
         AccountNumber(), " @ ", AccountServer());
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
