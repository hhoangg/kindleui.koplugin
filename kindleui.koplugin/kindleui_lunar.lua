--[[--
Vietnamese lunar calendar converter (Ho Ngoc Duc's algorithm).

WHY a dedicated Vietnamese implementation instead of a Chinese lunar library:
the astronomical events (new moons, solar terms) that anchor the calendar are
resolved against the *local* civil timezone. Vietnam uses UTC+7, China uses
UTC+8. A new moon falling in that one-hour window lands on a different civil
day in each country, so the two calendars drift apart by a day several times a
year - occasionally including Tet Nguyen Dan itself. Hence TIMEZONE = 7.

Pure Lua, `math` only, no data tables and no I/O, so it can be unit-tested
outside KOReader.
]]

local floor = math.floor
local sin = math.sin
local PI = math.pi

-- Vietnam civil offset used for every astronomical rounding below.
local TIMEZONE = 7

local Lunar = {}

-- Julian day number from a Gregorian (or Julian, before 1582-10-15) date.
local function jdFromDate(dd, mm, yy)
    local a = floor((14 - mm) / 12)
    local y = yy + 4800 - a
    local m = mm + 12 * a - 3
    local jd = dd + floor((153 * m + 2) / 5) + 365 * y
        + floor(y / 4) - floor(y / 100) + floor(y / 400) - 32045
    -- Before JDN 2299161 (1582-10-15) the Julian calendar applies: no century
    -- rule, so recompute without the /100 and /400 terms.
    if jd < 2299161 then
        jd = dd + floor((153 * m + 2) / 5) + 365 * y + floor(y / 4) - 32083
    end
    return jd
end

-- Julian day (UTC, fractional) of the k-th new moon since 1900-01-01.
local function newMoon(k)
    local T = k / 1236.85
    local T2 = T * T
    local T3 = T2 * T
    local dr = PI / 180
    local Jd1 = 2415020.75933 + 29.53058868 * k + 0.0001178 * T2 - 0.000000155 * T3
    Jd1 = Jd1 + 0.00033 * sin((166.56 + 132.87 * T - 0.009173 * T2) * dr)
    local M = 359.2242 + 29.10535608 * k - 0.0000333 * T2 - 0.00000347 * T3
    local Mpr = 306.0253 + 385.81691806 * k + 0.0107306 * T2 + 0.00001236 * T3
    local F = 21.2964 + 390.67050646 * k - 0.0016528 * T2 - 0.00000239 * T3
    local C1 = (0.1734 - 0.000393 * T) * sin(M * dr) + 0.0021 * sin(2 * dr * M)
    C1 = C1 - 0.4068 * sin(Mpr * dr) + 0.0161 * sin(dr * 2 * Mpr)
    C1 = C1 - 0.0004 * sin(dr * 3 * Mpr)
    C1 = C1 + 0.0104 * sin(dr * 2 * F) - 0.0051 * sin(dr * (M + Mpr))
    C1 = C1 - 0.0074 * sin(dr * (M - Mpr)) + 0.0004 * sin(dr * (2 * F + M))
    C1 = C1 - 0.0004 * sin(dr * (2 * F - M)) - 0.0006 * sin(dr * (2 * F + Mpr))
    C1 = C1 + 0.0010 * sin(dr * (2 * F - Mpr)) + 0.0005 * sin(dr * (2 * Mpr + M))
    local deltat
    -- Two-branch TD-UT correction: the pre-1600 (T < -11) polynomial is not
    -- valid for modern dates and vice versa.
    if T < -11 then
        deltat = 0.001 + 0.000839 * T + 0.0002261 * T2 - 0.00000845 * T3 - 0.000000081 * T * T3
    else
        deltat = -0.000278 + 0.000265 * T + 0.000262 * T2
    end
    return Jd1 + C1 - deltat
end

-- Apparent geocentric longitude of the sun, radians in [0, 2pi).
local function sunLongitude(jdn)
    local T = (jdn - 2451545.0) / 36525
    local T2 = T * T
    local dr = PI / 180
    local M = 357.52910 + 35999.05030 * T - 0.0001559 * T2 - 0.00000048 * T * T2
    local L0 = 280.46645 + 36000.76983 * T + 0.0003032 * T2
    local DL = (1.914600 - 0.004817 * T - 0.000014 * T2) * sin(dr * M)
    DL = DL + (0.019993 - 0.000101 * T) * sin(dr * 2 * M) + 0.000290 * sin(dr * 3 * M)
    local L = L0 + DL
    L = L * dr
    L = L - PI * 2 * floor(L / (PI * 2))
    return L
end

-- Which 30-degree zodiac sector the sun occupies at local midnight, 0..11.
local function getSunLongitude(dayNumber, tz)
    return floor(sunLongitude(dayNumber - 0.5 - tz / 24) / PI * 6)
end

-- Local civil day containing the k-th new moon.
local function getNewMoonDay(k, tz)
    return floor(newMoon(k) + 0.5 + tz / 24)
end

-- Start of lunar month 11, the month that must contain the winter solstice.
local function getLunarMonth11(yy, tz)
    local off = jdFromDate(31, 12, yy) - 2415021
    local k = floor(off / 29.530588853)
    local nm = getNewMoonDay(k, tz)
    -- Sector >= 9 means the solstice already passed; step back one lunation.
    if getSunLongitude(nm, tz) >= 9 then
        nm = getNewMoonDay(k - 1, tz)
    end
    return nm
end

-- In a 13-month lunar year, the leap month is the first month that contains no
-- principal solar term, i.e. the first month whose sun sector repeats the
-- previous month's. Returns its 1-based offset from month 11.
local function getLeapMonthOffset(a11, tz)
    local k = floor((a11 - 2415021.076998695) / 29.530588853 + 0.5)
    local last = 0
    local i = 1
    local arc = getSunLongitude(getNewMoonDay(k + i, tz), tz)
    repeat
        last = arc
        i = i + 1
        arc = getSunLongitude(getNewMoonDay(k + i, tz), tz)
    until arc == last or i >= 14
    return i - 1
end

local CAN = { "Giáp", "Ất", "Bính", "Đinh", "Mậu", "Kỷ", "Canh", "Tân", "Nhâm", "Quý" }
local CHI = { "Tý", "Sửu", "Dần", "Mão", "Thìn", "Tỵ", "Ngọ", "Mùi", "Thân", "Dậu", "Tuất", "Hợi" }

--- Sexagenary (can chi) name of a lunar year.
-- The published offsets (+6 mod 10, +8 mod 12) index a 0-based array, so a
-- "+ 1" shift is required for Lua's 1-based tables.
function Lunar.canChi(lunarYear)
    return CAN[(lunarYear + 6) % 10 + 1] .. " " .. CHI[(lunarYear + 8) % 12 + 1]
end

--- Convert a solar (Gregorian) date to the Vietnamese lunar date.
-- @return table { day, month, year, leap (bool), canchi (string) }
function Lunar.fromSolar(dd, mm, yy)
    local tz = TIMEZONE
    local dayNumber = jdFromDate(dd, mm, yy)
    local k = floor((dayNumber - 2415021.076998695) / 29.530588853)
    local monthStart = getNewMoonDay(k + 1, tz)
    if monthStart > dayNumber then
        monthStart = getNewMoonDay(k, tz)
    end
    local a11 = getLunarMonth11(yy, tz)
    local b11 = a11
    local lunarYear
    if a11 >= monthStart then
        lunarYear = yy
        a11 = getLunarMonth11(yy - 1, tz)
    else
        lunarYear = yy + 1
        b11 = getLunarMonth11(yy + 1, tz)
    end
    local lunarDay = dayNumber - monthStart + 1
    local diff = floor((monthStart - a11) / 29)
    local lunarLeap = false
    local lunarMonth = diff + 11
    -- More than 365 days between two month-11 starts means 13 lunar months,
    -- so one of them is a leap month and everything after it shifts back one.
    if b11 - a11 > 365 then
        local leapMonthDiff = getLeapMonthOffset(a11, tz)
        if diff >= leapMonthDiff then
            lunarMonth = diff + 10
            if diff == leapMonthDiff then
                lunarLeap = true
            end
        end
    end
    if lunarMonth > 12 then
        lunarMonth = lunarMonth - 12
    end
    -- Months 11 and 12 counted from the *previous* month-11 anchor still belong
    -- to the preceding lunar year.
    if lunarMonth >= 11 and diff < 4 then
        lunarYear = lunarYear - 1
    end
    return {
        day = lunarDay,
        month = lunarMonth,
        year = lunarYear,
        leap = lunarLeap,
        canchi = Lunar.canChi(lunarYear),
    }
end

--- Today's lunar date, from the device's local civil date.
function Lunar.today()
    local t = os.date("*t")
    return Lunar.fromSolar(t.day, t.month, t.year)
end

--- Display string, e.g. "13 tháng 7 · Bính Ngọ".
function Lunar.format(t)
    local m = tostring(t.month)
    if t.leap then
        m = m .. " (nhuận)"
    end
    return string.format("%d tháng %s · %s", t.day, m, t.canchi)
end

return Lunar
