//+------------------------------------------------------------------+
//| KimieSignalExecutorMT4.mq4                                       |
//| MT4 port of KimieSignalExecutor - executes Zizi's engine signals.|
//|                                                                  |
//| CHANNEL: reads the Google Sheet gviz CSV (rows posted by the     |
//| signal publisher the moment a signal fires). Google has generous |
//| rate limits unlike the GitHub API (60/hr shared by all terminals)|
//| so MT4 terminals can poll fast without starving the MT5 EA.      |
//|                                                                  |
//| SAFETY RAILS (same as MT5 version)                               |
//|  - MaxLots cap per trade                                          |
//|  - Risk cap: lot auto-sized so SL risk <= RiskPct% of balance    |
//|  - MaxLossesPerDay (a win today resets the counter per spec)     |
//|  - Session flat: closes all EA positions at SessionCloseGMT      |
//|  - Executed signal ids in global vars (no double entry)          |
//|  - Kill-switch rows (type=kill) read from the same sheet         |
//|  - SymbolSuffix for brokers like CXM (XAUUSDc etc.)              |
//|                                                                  |
//| INSTALL (MT4)                                                     |
//|  1. Copy to <MT4 data folder>/MQL4/Experts/, compile (F7)        |
//|  2. Tools > Options > Expert Advisors:                           |
//|     Allow WebRequest for: https://docs.google.com                |
//|  3. VALIDATION RULE: start on a DEMO account first (>=20 trades)|
//|     before attaching to any live MT4 account.                   |
//|  4. One chart per terminal. Enable AutoTrading.                  |
//+------------------------------------------------------------------+
#property copyright "Kimie & Zizi"
#property version   "1.01"
#property strict

input string SheetCSVURL = "https://docs.google.com/spreadsheets/d/1XTLK5qdtGK5UmvzUYxKo6qMDLCFw6twbLKqMffTbeiE/gviz/tq?tqx=out:csv";
input double MaxLots        = 0.03;   // hard cap per trade
input double RiskPct       = 2.0;    // max % of balance risked via SL
input int    MaxLossesPerDay = 2;    // stop trading after N losses today
input int    SessionCloseGMT = 21;   // flatten all positions at this hour UTC
input int    PollSeconds    = 75;    // sheet poll interval
input int    MaxSignalAgeSec = 600;  // ignore signals older than this
input int    MagicNumber    = 778899;
input string SymbolSuffix  = "";    // e.g. "c" for CXM (XAUUSDc). empty = plain
input string TradePairs    = "";    // comma list; empty = all signal pairs

#define GV_PREFIX "KIMIE_EA4_"

bool g_haltedToday = false;
int  g_lastHaltDay = -1;

//+------------------------------------------------------------------+
// self-announce to the Google Sheet (same form as reporters) so the
// install is verifiable remotely. type=ea4init / type=ea4entry rows
// are ignored by trade stats (only type=trade with pl counts).
input string AnnounceFormURL = "https://docs.google.com/forms/d/e/1FAIpQLSfCP6f4rb8kW_DBCICbc5II7eiyPOwSCoRAJGH3aGcPoUMQmw/formResponse";
input string AnnounceEntry   = "entry.1119234569";

string UrlEnc(string s)
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

void Announce(string payload)
{
   string body = AnnounceEntry + "=" + UrlEnc(payload);
   char post[];
   StringToCharArray(body, post, 0, StringLen(body), CP_ACP);
   ArrayResize(post, StringLen(body));
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   char result[];
   string resHeaders;
   WebRequest("POST", AnnounceFormURL, headers, 8000,
              post, result, resHeaders);
}

//+------------------------------------------------------------------+
string GvName(const string id)  { return GV_PREFIX + id; }
bool   IdDone(const string id)
{
   string gv = GvName("SIG_" + id);
   if(GlobalVariableCheck(gv)) return true;
   GlobalVariableSet(gv, 1);
   return false;
}
//+------------------------------------------------------------------+
int CountOpenPositions(string symbol)
{
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber) continue;
      if(OrderType() > OP_SELL) continue;
      if(StringLen(symbol) == 0 || OrderSymbol() == symbol) n++;
   }
   return n;
}
//+------------------------------------------------------------------+
void CloseAllEAPositions(string why)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber) continue;
      if(OrderType() > OP_SELL) continue;
      for(int attempt = 0; attempt < 3; attempt++)
      {
         RefreshRates();
         double px = (OrderType() == OP_BUY) ? Bid : Ask;
         if(OrderClose(OrderTicket(), OrderLots(), px, 30, clrRed)) break;
         Sleep(500);
      }
   }
   if(StringLen(why) > 0) Print("SESSION FLAT: ", why);
}
//+------------------------------------------------------------------+
int LossesToday()
{
   datetime dayStart = TimeGMT() - (TimeGMT() % 86400);
   int losses = 0, wins = 0;
   for(int i = OrdersHistoryTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(OrderMagicNumber() != MagicNumber) continue;
      if(OrderType() > OP_SELL) continue;
      if(OrderCloseTime() < dayStart) break;  // newest first
      double p = OrderProfit() + OrderSwap() + OrderCommission();
      if(p < 0) losses++;
      else if(p > 0) wins++;
   }
   if(wins > 0) return 0;   // spec: only pure losing streaks halt
   return losses;
}
//+------------------------------------------------------------------+
double CalcLots(string symbol, double slDist)
{
   double balance = AccountBalance();
   double riskMoney = balance * RiskPct / 100.0;
   double tickValue = MarketInfo(symbol, MODE_TICKVALUE);
   double tickSize  = MarketInfo(symbol, MODE_TICKSIZE);
   if(tickValue <= 0 || tickSize <= 0 || slDist <= 0) return 0.01;
   double riskPerLot = (slDist / tickSize) * tickValue;
   if(riskPerLot <= 0) return 0.01;
   double lots = riskMoney / riskPerLot;
   double step = MarketInfo(symbol, MODE_LOTSTEP);
   double minL = MarketInfo(symbol, MODE_MINLOT);
   double maxL = MarketInfo(symbol, MODE_MAXLOT);
   if(step > 0) lots = MathFloor(lots / step) * step;
   lots = MathMax(minL, MathMin(lots, MathMin(maxL, MaxLots)));
   return NormalizeDouble(lots, 2);
}
//+------------------------------------------------------------------+
bool ExecuteSignal(string pair, string dir, double slDist, double tpDist,
                   double lot)
{
   string symbol = pair + SymbolSuffix;
   ResetLastError();
   if(!SymbolSelect(symbol, true))
   {
      Print("SYMBOL NOT AVAILABLE on this broker: ", symbol,
            " (check SymbolSuffix input)");
      return false;
   }
   if(CountOpenPositions(symbol) > 0)
   {
      Print("SKIP: position already open on ", symbol);
      return false;
   }
   RefreshRates();
   double price, sl, tp;
   int    type;
   int    digits = (int)MarketInfo(symbol, MODE_DIGITS);
   bool isLong = (dir == "LONG");
   if(isLong) { type = OP_BUY;  price = MarketInfo(symbol, MODE_ASK);
                sl = price - slDist; tp = price + tpDist; }
   else       { type = OP_SELL; price = MarketInfo(symbol, MODE_BID);
                sl = price + slDist; tp = price - tpDist; }
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);
   double useLot = (lot > 0) ? MathMin(lot, MaxLots)
                             : CalcLots(symbol, slDist);
   int ticket = OrderSend(symbol, type, useLot, price, 30, sl, tp,
                          "Zizi signal executor MT4", MagicNumber, 0,
                          isLong ? clrDodgerBlue : clrTomato);
   if(ticket < 0)
   {
      Print("ORDER FAILED ", symbol, " ", dir, " err=", GetLastError(),
            " (check AutoTrading + trade permission)");
      return false;
   }
   Print("EXECUTED ", symbol, " ", dir, " lot=", useLot,
         " sl=", sl, " tp=", tp, " ticket=", ticket);
   Announce("type=ea4entry;acct=" + IntegerToString(AccountNumber())
            + ";pair=" + symbol + ";dir=" + dir
            + ";lot=" + DoubleToString(useLot, 2)
            + ";sl=" + DoubleToString(sl, Digits)
            + ";tp=" + DoubleToString(tp, Digits)
            + ";ticket=" + IntegerToString(ticket)
            + ";tm=" + TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS));
   return true;
}
//+------------------------------------------------------------------+
// payload helpers: "key=value;key=value" -> value of key
string Field(string payload, string key)
{
   string pat = key + "=";
   int p = StringFind(payload, pat);
   if(p < 0) return "";
   p += StringLen(pat);
   int e = StringFind(payload, ";", p);
   if(e < 0) e = StringLen(payload);
   return StringSubstr(payload, p, e - p);
}
//+------------------------------------------------------------------+
// 3rd quoted CSV field of a line like "a","b","c"
string CsvThirdField(string line)
{
   int q = -1, f = 0;
   for(int i = 0; i < StringLen(line); i++)
   {
      if(StringGetChar(line, i) == '"')
      {
         if(q < 0) { q = i; }
         else
         {
            f++;
            if(f == 3) return StringSubstr(line, q + 1, i - q - 1);
            q = -1;
         }
      }
   }
   return "";
}
//+------------------------------------------------------------------+
void ProcessSheet()
{
   char post[];
   char result[];
   string resHeaders;
   ResetLastError();
   int status = WebRequest("GET", SheetCSVURL, "", 8000,
                           post, result, resHeaders);
   if(status != 200)
   {
      Print("WebRequest failed status=", status, " err=", GetLastError(),
            " (allowlist https://docs.google.com)");
      return;
   }
   string csv = CharArrayToString(result);

   // take only the TAIL of the csv (last ~9000 chars = ~60-80 rows,
   // far more than the 10-min freshness window even with 12 reporters)
   int len = StringLen(csv);
   string tail = csv;
   if(len > 9000)
   {
      int cut = StringLen(csv) - 9000;
      int nl = StringFind(csv, "\n", cut);
      tail = (nl > 0) ? StringSubstr(csv, nl + 1) : StringSubstr(csv, cut);
   }

   // split into lines (newest signal rows are at the end)
   string lines[];
   int n = StringSplit(tail, '\n', lines);
   if(n < 2) return;

   // walk NEWEST -> OLDEST, bounded
   int checked = 0;
   for(int i = n - 1; i >= 1 && checked < 80; i--)
   {
      string payload = CsvThirdField(lines[i]);
      if(StringLen(payload) < 5) continue;
      checked++;
      string type = Field(payload, "type");

      if(type == "kill")
      {
         double kpub = StringToDouble(Field(payload, "pub"));
         string kgv = GvName("KILL_PUB");
         double last = GlobalVariableCheck(kgv) ? GlobalVariableGet(kgv) : 0;
         if(kpub > last)
         {
            GlobalVariableSet(kgv, kpub);
            GlobalVariableSet(GvName("ENABLED"),
                              (Field(payload, "enabled") == "1") ? 1 : 0);
            Print("KILL-SWITCH update: enabled=" + Field(payload, "enabled"));
         }
         continue;
      }
      if(type != "signal") continue;

      // ---- a signal row: run the full gate chain (same order as MT5) ----
      string id    = Field(payload, "id");
      string pair  = Field(payload, "pair");
      string dir   = Field(payload, "dir");
      double slDist = StringToDouble(Field(payload, "sl_dist"));
      double tpDist = StringToDouble(Field(payload, "tp_dist"));
      double lot   = StringToDouble(Field(payload, "lot"));
      long   pub   = StringToInteger(Field(payload, "pub"));

      if(StringLen(id) == 0 || StringLen(pair) == 0) continue;
      if(IdDone(id)) continue;                       // already executed/seen

      // master kill-switch state
      if(GlobalVariableGet(GvName("ENABLED")) == 0) return;

      // session gates (GMT)
      datetime g = TimeGMT();
      int hour = TimeHour(g);
      int dow  = TimeDayOfWeek(g);
      int doy  = TimeDayOfYear(g);
      if(hour >= SessionCloseGMT || dow == 6 || dow == 0)
      {
         if(CountOpenPositions("") > 0) CloseAllEAPositions("after session");
         return;
      }
      if(hour < 7 && dow >= 1 && dow <= 5) return;

      // daily circuit breaker
      if(g_lastHaltDay != doy) { g_haltedToday = false; g_lastHaltDay = doy; }
      if(!g_haltedToday && LossesToday() >= MaxLossesPerDay)
      {
         g_haltedToday = true;
         Print("CIRCUIT BREAKER: ", LossesToday(),
               " losses today - halted until tomorrow GMT.");
      }
      if(g_haltedToday) return;

      // freshness
      long age = (long)g - pub;
      if(age < 0) age = 0;
      if(age > MaxSignalAgeSec) continue;
      if(dir != "LONG" && dir != "SHORT") continue;
      if(slDist <= 0 || tpDist <= 0) continue;

      // pair filter
      if(StringLen(TradePairs) > 0)
      {
         string want = "," + TradePairs + ",";
         string have = "," + pair + ",";
         if(StringFind(want, have) < 0) continue;
      }
      ExecuteSignal(pair, dir, slDist, tpDist, lot);
   }
}
//+------------------------------------------------------------------+
int OnInit()
{
   if(!GlobalVariableCheck(GvName("ENABLED")))
      GlobalVariableSet(GvName("ENABLED"), 1);   // default: enabled
   EventSetTimer(MathMax(30, PollSeconds));
   Print("KimieSignalExecutorMT4 started. Magic=", MagicNumber,
         " MaxLots=", MaxLots, " Suffix=", SymbolSuffix);
   Announce("type=ea4init;acct=" + IntegerToString(AccountNumber())
            + ";srv=" + AccountServer()
            + ";ver=mt4-executor-1.01"
            + ";tm=" + TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS));
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason) { EventKillTimer(); }
void OnTimer() { ProcessSheet(); }
//+------------------------------------------------------------------+
