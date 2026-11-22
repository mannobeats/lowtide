import Foundation
import Testing
@testable import LowtideKit

/// The bar's inline answers.
@Suite struct CommandBarAnswerTests {
    func title(_ q: String) -> String { Answers.answer(q)?.title ?? "no answer for \(q)" }

    @Test func calculatorPrecedenceAndPowers() {
        #expect(title("2+2*3") == "8")
        #expect(title("2^3^2") == "512")
        let neg = Answers.answer("-2^2")
        #expect(neg?.title == "-4")
        #expect(neg?.reuse == "(-4)")
        #expect(neg?.kind == .math)
        #expect(neg?.subtitle == "Return copies")
    }

    @Test func calculatorPercentConstantsFunctions() {
        #expect(title("200 + 10%") == "220")
        #expect(title("200 - 10%") == "180")
        #expect(title("10% of 50") == "5")
        #expect(title("10% de 50") == "5")
        #expect(title("50%") == "0.5")
        #expect(title("sqrt(16)+2π") == "10.28318531")
        #expect(title("2(3)") == "6")
        #expect(title("3sqrt(4)") == "6")
        #expect(title("3 x 4") == "12")
        #expect(title("6 ÷ 3 − 1") == "1")
        #expect(title("log10(1000)") == "3")
        #expect(title("[2+1]*2") == "6")
        #expect(title("2+2=") == "4")
    }

    @Test func calculatorFormatting() {
        #expect(title("1234567*1000") == "1,234,567,000")
        #expect(title("1e12*1") == "1e12")
        #expect(title("1/3000000*1") == "3.3333333e-7")
        let sum = Answers.answer("0.1+0.2")
        #expect(sum?.title == "0.3")
        #expect(sum?.reuse == "0.3")
        #expect(title("1,234+1") == "1,235")
        #expect(title("1,5+1") == "2.5")
        #expect(title("1.234,5+0,5") == "1,235")
        #expect(title("-0*1") == "0")
        #expect(Answers.answer("10/4")?.reuse == "2.5")
        #expect(Answers.answer("2*3")?.reuse == "6")
    }

    @Test func calculatorClosesBracketsVirtually() {
        let a = Answers.answer("(2+3")
        #expect(a?.title == "5")
        #expect(a?.subtitle == "(2+3) · Return copies")
        #expect(Answers.answer("2+(3")?.subtitle == "2+(3) · Return copies")
        #expect(Answers.answer("[(1+1")?.subtitle == "[(1+1)] · Return copies")
    }

    @Test(arguments: ["2026-07-27", "27/07/2026", "10:30", "5", "code 1234", "2)", "(2]", "1/0", "sqrt(-1)", "ln(0)",
                      "asin(2)", "x = 2", "2==2", "pi", "sqrt 4", "2x", "hello"])
    func calculatorRejectsNonMath(_ q: String) {
        #expect(Answers.math(q) == nil)
    }

    @Test func calculatorEdges() {
        #expect(title("5-3") == "2")
        #expect(Answers.math(String(repeating: "(", count: 40) + "1") == nil)
        #expect(Answers.math(String(repeating: "1+", count: 70) + "1") == nil)
    }

    @Test func unitConversions() {
        #expect(title("100 km to mi") == "62.14 mi")
        #expect(title("100km in mi") == "62.14 mi")
        #expect(title("5 in to cm") == "12.7 cm")
        #expect(title("72 f to c") == "22.22 °C")
        #expect(title("100 °c to °f") == "212 °F")
        #expect(title("-40 c to f") == "-40 °F")
        #expect(title("5.9 ft to ft") == "5 ft 10.8 in")
        #expect(title("178 cm to ft") == "5 ft 10.1 in")
        #expect(title("6 in to ft") == "0.5 ft")
        #expect(title("1 gib to mb") == "1,073.7 MB")
        #expect(title("1500 mb to gb") == "1.5 GB")
        #expect(title("2 h para min") == "120 min")
        #expect(title("3 pés em cm") == "91.44 cm")
        #expect(title("1 cup to ml") == "236.6 mL")
        #expect(Answers.answer("100 km to mi")?.kind == .units)
        #expect(Answers.units("5 kg to mi") == nil)
        #expect(Answers.units("5 km") == nil)
    }

    @Test func colourPreviewAndConversion() {
        let p = Answers.answer("#ff0000")
        #expect(p?.kind == .colorPreview)
        #expect(p?.title == "#ff0000")
        #expect(p?.copy == "#ff0000")
        #expect(p?.swatch?.css == "rgba(255, 0, 0, 1)")
        #expect(Answers.answer("ff0000") == nil)
        #expect(Answers.colorPreview("#ff00") != nil)
        #expect(Answers.colorPreview("#ff00f") == nil)

        let c = Answers.answer("#f00 to rgb")
        #expect(c?.kind == .color)
        #expect(c?.title == "rgb(255, 0, 0)")
        #expect(title("#f00 to rgba") == "rgba(255, 0, 0, 1)")
        #expect(title("rgb(255 0 0 / 50%) to hex") == "#FF000080")
        #expect(title("hsl(120deg, 100%, 50%) to swift") == "Color(red: 0.000, green: 1.000, blue: 0.000)")
        #expect(title("#336699 to hsl") == "hsl(210, 50%, 40%)")
        #expect(title("rgba(0, 0, 255, 0.25) to hsl") == "hsla(240, 100%, 50%, 0.25)")
        #expect(title("Color(red: 1, green: 0.5, blue: 0, opacity: 0.5) to hex") == "#FF800080")
        #expect(Answers.colorPreview("rgb(300, 0, 0)") == nil)
    }

    func day(_ y: Int, _ m: Int, _ d: Int) -> Int { Answers.daysFromCivil(y, m, d) }

    /// Noon UTC on 29 September 2026, a Tuesday.
    var clock: AnswerClock { AnswerClock(unix: day(2026, 9, 29) * 86_400 + 12 * 3600, offset: 0) }

    func date(_ q: String) -> [String]? {
        Answers.dateAnswer(q, clock: clock).map { [$0.title, $0.subtitle] }
    }

    @Test func calendarArithmetic() {
        #expect(Answers.civilFromDays(0) == (1970, 1, 1))
        #expect(Answers.civilFromDays(day(2024, 2, 29)) == (2024, 2, 29))
        #expect(Answers.weekday(day(2026, 9, 29)) == "Tuesday")
        #expect(Answers.addMonths(day(2026, 1, 31), 1) == day(2026, 2, 28))
        #expect(Answers.addMonths(day(2024, 2, 29), 12) == day(2025, 2, 28))
        #expect(Answers.fullDate(day(2026, 9, 29)) == "Tuesday, 29 September 2026")
        #expect(Answers.shortTime(15 * 3600 + 4 * 60) == "3:04 PM")
        #expect(Answers.shortTime(30) == "12:00 AM")
        #expect(Answers.civilFromDays(-1) == (1969, 12, 31))
    }

    @Test func relativeDates() {
        #expect(date("in 3 weeks") == ["20 October 2026", "Tuesday"])
        #expect(date("3 days ago") == ["26 September 2026", "Saturday"])
        #expect(date("today + 10 days") == ["9 October 2026", "Friday"])
        #expect(date("today - 1 day") == ["28 September 2026", "Monday"])
        #expect(date("in 2 months") == ["29 November 2026", "Sunday"])
        #expect(date("em 1 ano") == ["29 September 2027", "Wednesday"])
        #expect(date("vor 2 Tagen") == ["27 September 2026", "Sunday"])
        #expect(date("3日後") == ["2 October 2026", "Friday"])
        #expect(date("3 days") == nil)
        #expect(date("buy 3 days ago stuff") == nil)
    }

    @Test func daysUntilDates() {
        #expect(date("days until 12/25") == ["87 days", "Friday, 25 December 2026"])
        #expect(date("until 9/30") == ["1 day", "Wednesday, 30 September 2026"])
        #expect(date("days until 1/1") == ["94 days", "Friday, 1 January 2027"])
        #expect(date("until 2026-09-29") == ["0 days", "Tuesday, 29 September 2026"])
        #expect(date("until 13/40") == nil)
    }

    @Test func timeInCities() {
        // Noon UTC is 9 PM in Tokyo, which has no daylight saving.
        #expect(date("time in tokyo") == ["9:00 PM", "Tokyo · Tuesday, 29 September 2026"])
        #expect(date("hora em nova york")?[1].hasPrefix("New York · ") == true)
        #expect(date("time in sao paulo")?[1].hasPrefix("Sao Paulo · ") == true)
        #expect(date("время москва")?[1].hasPrefix("Moscow · ") == true)
        #expect(date("what time is it in london")?[1].hasPrefix("London · ") == true)
        #expect(date("time in atlantis") == nil)
        #expect(Answers.answer("time in tokyo")?.kind == .date)
    }

    @Test func webAddresses() {
        #expect(Answers.webAddress("example.com") == "https://example.com")
        #expect(Answers.webAddress(" example.com/x ") == "https://example.com/x")
        #expect(Answers.webAddress("https://x.y/z?q=1") == "https://x.y/z?q=1")
        #expect(Answers.webAddress("http://localhost:3000") == "http://localhost:3000")
        #expect(Answers.webAddress("sub.example.co.uk:8080/a") == "https://sub.example.co.uk:8080/a")
        for q in ["a@b.com", "notes.txt", "readme.md", "hello world", "https://", "example", "ftp://x.com", "1.5"] {
            #expect(Answers.webAddress(q) == nil, "\(q)")
        }
    }

    @Test func colourFormatsOfAPick() {
        let formats = Dictionary(uniqueKeysWithValues: ColorFormats.all("#336699"))
        #expect(formats["HEX"] == "#336699")
        #expect(formats["RGB"] == "rgb(51, 102, 153)")
        #expect(formats["HSL"] == "hsl(210, 50%, 40%)")
        #expect(formats["SwiftUI"] == "Color(red: 0.200, green: 0.400, blue: 0.600)")
        #expect(formats["OKLCH"]?.hasPrefix("oklch(") == true)
        #expect(ColorFormats.all("#fff").isEmpty)
        #expect(ColorFormats.oklch(255, 255, 255) == "oklch(100.0% 0.000 0.0)")
    }
}
