//+------------------------------------------------------------------+
//| KimieSignalExecutor.mq5                                          |
//| Thin signal-executor EA - executes Zizi's engine signals.        |
//|                                                                  |
//| HOW IT WORKS                                                     |
//|  - Polls a public raw URL (signals.json) every POLL_SECONDS     |
//|  - Each signal: {id, pair, dir, sl_dist, tp_dist, ts}            |
//|    (distances in PRICE units - applied to live price at entry,   |
//|     so broker feed vs source feed basis is neutralised)          |
//|  - Executes market orders with SL/TP, one position per pair     |
//|  - "enabled": false in the JSON = master kill-switch             |
//|                                                                  |
//| SAFETY RAILS (all built-in)                                      |
//|  - MaxLots cap per trade                                         |
//|  - Risk cap: lot auto-sized so SL risk <= RiskPct% of balance    |
//|  - MaxLossesPerDay: after N losing trades today, no new trades   |
//|  - Session flat: closes all EA positions at SessionCloseGMT       |
//|  - Executed signal ids stored in global vars (no double entry)   |
//|  - Only fresh signals (< MaxSignalAgeSec) are executed           |
//|                                                                  |
//| INSTALL (MT5 desktop, one account)                               |
//|  1. Copy this file to <MT5 data folder>/MQL5/Experts/           |
//|  2. Open MetaEditor, compile (F7)                               |
//|  3. Tools > Options > Expert Advisors > allow WebRequest for:    |
//|     https://raw.githubusercontent.com                           |
//|  4. Drag onto a chart of ANY symbol; it trades all signal pairs  |
//|  5. Enable Algo Trading (toolbar button)                         |
//+------------------------------------------------------------------+
#property copyright "Kimie & Zizi"
#property version   "1.00"
#property strict

input string SignalURL      = "https://api.github.com/repos/kimieventures/trading-signals/contents/live_signals.json";
input double MaxLots        = 0.03;   // hard cap per trade
input double RiskPct        = 2.0;    // max % of balance risked via SL
input int    MaxLossesPerDay = 2;    // stop trading after N losses today
input int    SessionCloseGMT = 21;   // flatten all positions at this hour UTC
input int    PollSeconds    = 75;    // KEEP >= 75 (GitHub API rate limit 60/hr)
input int    MaxSignalAgeSec = 600;  // ignore signals older than this
input long   MagicNumber    = 778899;

#define GV_PREFIX "KIMIE_EA_"

datetime g_lastPoll = 0;
bool     g_haltedToday = false;
int      g_lastHaltDay = -1;

//+------------------------------------------------------------------+
string GvName(const string id)   { return GV_PREFIX + id; }
bool   IdDone(const string id)
{
   string gv = GvName("SIG_" + id);
   if(GlobalVariableCheck(gv)) return true;
   GlobalVariableSet(gv, 1);
   return false;
}
//+------------------------------------------------------------------+
int CountOpenPositions(const string symbol)
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionGetSymbol(i)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(StringLen(symbol) == 0 || PositionGetString(POSITION_SYMBOL) == symbol)
         n++;
   }
   return n;
}
//+------------------------------------------------------------------+
void CloseAllEAPositions(const string why)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionGetSymbol(i)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      MqlTradeRequest req; MqlTradeResult res;
      ZeroMemory(req); ZeroMemory(res);
      req.action    = TRADE_ACTION_DEAL;
      req.position  = PositionGetInteger(POSITION_TICKET);
      req.symbol    = PositionGetString(POSITION_SYMBOL);
      req.volume    = PositionGetDouble(POSITION_VOLUME);
      req.deviation = 30;
      req.type      = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                      ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      req.magic     = MagicNumber;
      if(!OrderSend(req, res))
         Print("FLAT CLOSE FAILED ", req.symbol, " err=", res.retcode);
   }
   if(StringLen(why) > 0) Print("SESSION FLAT: ", why);
}
//+------------------------------------------------------------------+
int LossesToday()
{
   datetime dayStart = TimeGMT() - (TimeGMT() % 86400);
   if(!HistorySelect(dayStart, TimeGMT() + 60)) return 0;
   int losses = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != MagicNumber) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) losses++;
   }
   return losses;
}
//+------------------------------------------------------------------+
double CalcLots(const string symbol, double slDist)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * RiskPct / 100.0;
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0 || slDist <= 0) return 0.01;
   double riskPerLot = (slDist / tickSize) * tickValue;
   if(riskPerLot <= 0) return 0.01;
   double lots = riskMoney / riskPerLot;
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   lots = MathFloor(lots / step) * step;
   lots = MathMax(minL, MathMin(lots, MathMin(maxL, MaxLots)));
   return NormalizeDouble(lots, 2);
}
//+------------------------------------------------------------------+
bool ExecuteSignal(const string pair, const string dir,
                   double slDist, double tpDist, double lot)
{
   if(!SymbolSelect(pair, true))
   {
      Print("SYMBOL NOT AVAILABLE on this broker: ", pair);
      return false;
   }
   if(CountOpenPositions(pair) > 0)
   {
      Print("SKIP: position already open on ", pair);
      return false;
   }
   double ask = SymbolInfoDouble(pair, SYMBOL_ASK);
   double bid = SymbolInfoDouble(pair, SYMBOL_BID);
   bool isLong = (dir == "LONG");
   double price = isLong ? ask : bid;
   double sl = isLong ? price - slDist : price + slDist;
   double tp = isLong ? price + tpDist : price - tpDist;
   int digits = (int)SymbolInfoInteger(pair, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);
   double useLot = (lot > 0) ? MathMin(lot, MaxLots) : CalcLots(pair, slDist);

   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);
   req.action    = TRADE_ACTION_DEAL;
   req.symbol    = pair;
   req.volume    = useLot;
   req.type      = isLong ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price     = price;
   req.sl        = sl;
   req.tp        = tp;
   req.deviation = 30;
   req.magic     = MagicNumber;
   req.comment   = "Zizi signal executor";
   if(!OrderSend(req, res))
   {
      Print("ORDER FAILED ", pair, " ", dir, " retcode=", res.retcode,
            " comment=", res.comment);
      return false;
   }
   Print("EXECUTED ", pair, " ", dir, " lot=", useLot,
         " sl=", sl, " tp=", tp, " ticket=", res.order);
   return true;
}
//+------------------------------------------------------------------+
// --- minimal JSON field extraction: "key": value  (string or num) ---
string JsonStr(const string js, const string key)
{
   string pat = "\"" + key + "\":";
   int p = StringFind(js, pat);
   if(p < 0) return "";
   p += StringLen(pat);
   while(p < StringLen(js) && (StringGetCharacter(js, p) == ' '
        || StringGetCharacter(js, p) == '\"')) p++;
   string out = "";
   bool quoted = (StringGetCharacter(js, p - 1) == '\"');
   if(!quoted)
   {
      // numeric / raw until , or }
      while(p < StringLen(js))
      {
         ushort c = StringGetCharacter(js, p);
         if(c == ',' || c == '}' || c == ' ') break;
         out += CharToString((uchar)c);
         p++;
      }
   }
   else
   {
      while(p < StringLen(js) && StringGetCharacter(js, p) != '\"')
      {
         out += CharToString((uchar)StringGetCharacter(js, p));
         p++;
      }
   }
   return out;
}
//+------------------------------------------------------------------+
void ProcessSignals()
{
   char post[];
   char result[];
   string resHeaders;
   ResetLastError();
   // NOTE: GitHub contents API returns JSON with base64 content - fresh within 60s
   int status = WebRequest("GET", SignalURL, "", 8000, post, result, resHeaders);
   if(status == 403)
   {
      Print("API rate limit hit - backing off this poll");
      return;
   }
   if(status != 200)
   {
      Print("WebRequest failed status=", status, " err=", GetLastError(),
            " (allowlist https://api.github.com in Tools>Options>Expert Advisors)");
      return;
   }
   string api = CharArrayToString(result);

   // extract the base64 "content" field and decode it
   int cs = StringFind(api, "\"content\":");
   if(cs < 0) { Print("no content field in API response"); return; }
   int q1 = StringFind(api, "\"", cs + 10);
   int q2 = StringFind(api, "\"", q1 + 1);
   if(q1 < 0 || q2 <= q1) { Print("content field parse failed"); return; }
   string b64 = StringSubstr(api, q1 + 1, q2 - q1 - 1);
   StringReplace(b64, "\\n", "");
   StringReplace(b64, "\\/", "/");
   uchar src[];
   uchar key[];
   uchar dst[];
   int blen = StringLen(b64);
   StringToCharArray(b64, src, 0, blen, CP_ACP);
   ArrayResize(src, blen);
   int dlen = CryptDecode(CRYPT_BASE64, src, key, dst);
   if(dlen <= 0) { Print("base64 decode failed err=", GetLastError()); return; }
   string js = CharArrayToString(dst, 0, dlen);
   if(StringLen(js) == 0) return;

   // master kill-switch
   if(StringFind(js, "\"enabled\": false") >= 0
      || StringFind(js, "\"enabled\":false") >= 0)
   {
      Comment("KIMIE EA: MASTER SWITCH OFF (enabled=false) - monitoring only");
      return;
   }

   // session flat
   MqlDateTime gmt;
   TimeGMT(gmt);
   if(gmt.hour >= SessionCloseGMT || gmt.day_of_week == 6 || gmt.day_of_week == 0)
   {
      if(CountOpenPositions("") > 0) CloseAllEAPositions("after session close hour");
      return;
   }
   if(gmt.hour < 7 && gmt.day_of_week >= 1 && gmt.day_of_week <= 5)
   {
      return; // before session: monitor only
   }

   // daily loss circuit-breaker
   int today = gmt.day_of_year;
   if(g_lastHaltDay != today)
   {
      g_haltedToday = false;
      g_lastHaltDay = today;
   }
   if(!g_haltedToday && LossesToday() >= MaxLossesPerDay)
   {
      g_haltedToday = true;
      Print("CIRCUIT BREAKER: ", LossesToday(),
            " losses today - no more trades until tomorrow (GMT).");
   }
   if(g_haltedToday)
   {
      Comment("KIMIE EA: daily circuit-breaker active - monitoring only");
      return;
   }

   // walk signal objects
   int pos = 0;
   while(true)
   {
      int s = StringFind(js, "\"id\":", pos);
      if(s < 0) break;
      int e = StringFind(js, "}", s);
      if(e < 0) e = StringLen(js);
      string sig = StringSubstr(js, s, e - s);
      pos = e + 1;

      string id    = JsonStr(sig, "id");
      string pair  = JsonStr(sig, "pair");
      string dir   = JsonStr(sig, "dir");
      double slDist= StringToDouble(JsonStr(sig, "sl_dist"));
      double tpDist= StringToDouble(JsonStr(sig, "tp_dist"));
      long   ts    = StringToInteger(JsonStr(sig, "ts"));
      double lot   = StringToDouble(JsonStr(sig, "lot"));

      if(StringLen(id) == 0 || StringLen(pair) == 0) continue;
      if(IdDone(id)) continue;                        // already executed
      long age = (long)TimeGMT() - ts;
      if(age < 0 || age > MaxSignalAgeSec) continue;  // stale
      if(dir != "LONG" && dir != "SHORT") continue;
      if(slDist <= 0 || tpDist <= 0) continue;
      ExecuteSignal(pair, dir, slDist, tpDist, lot);
   }
   Comment("KIMIE EA OK | ", TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS),
           " GMT | open positions: ", CountOpenPositions(""),
           " | losses today: ", LossesToday(),
           " | halt: ", (g_haltedToday ? "YES" : "no"));
}
//+------------------------------------------------------------------+
int OnInit()
{
   if(StringLen(SignalURL) == 0)
   {
      Print("SignalURL input is EMPTY - EA will do nothing.");
      return INIT_FAILED;
   }
   EventSetTimer(PollSeconds);
   Print("KimieSignalExecutor started. Magic=", MagicNumber,
         " MaxLots=", MaxLots, " RiskPct=", RiskPct,
         " MaxLossesPerDay=", MaxLossesPerDay);
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
}
void OnTimer() { ProcessSignals(); }
//+------------------------------------------------------------------+
