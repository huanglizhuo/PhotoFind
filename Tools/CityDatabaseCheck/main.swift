// Runnable check for CityDatabase (F3.5.1). From SemanticPhotos/:
//   swiftc -o /tmp/citycheck Tools/CityDatabaseCheck/main.swift SemanticPhotos/Services/CityDatabase.swift
//   /tmp/citycheck SemanticPhotos/Resources/cities.sqlite

import Foundation
let db = CityDatabase(url: URL(fileURLWithPath: CommandLine.arguments[1]))
func check(_ label: String, _ lat: Double, _ lon: Double, _ expect: (String?) -> Bool) {
    let hit = db.nearest(latitude: lat, longitude: lon)
    let name = db.displayName(cityID: hit?.id, km: hit?.km)
    let ok = expect(name)
    print(ok ? "PASS" : "FAIL", label, name ?? "nil", hit.map { String(format: "%.1f km", $0.km) } ?? "")
    if !ok { exit(1) }
}
check("西湖", 30.2431, 120.1503) { $0 == "杭州 · 浙江 · 中国大陆" }
check("天安门", 39.9042, 116.4074) { $0?.hasPrefix("北京") == true && $0?.contains("北京市") == false }
check("东京站", 35.6812, 139.7671) { $0?.hasSuffix("日本") == true }
check("巴黎", 48.8584, 2.2945) { $0?.hasSuffix("法国") == true }
check("太平洋中部", 0, -150) { $0 == nil }
let km = CityDatabase.distanceKm(39.9042, 116.4074, 31.2304, 121.4737)
print(abs(km - 1067) < 15 ? "PASS" : "FAIL", "北京-上海距离", Int(km), "km")
// "附近": a point ~50 km from the nearest city should read "××附近".
var near: (Double, Double)?
for lat in stride(from: 40.0, to: 50.0, by: 0.37) { for lon in stride(from: 90.0, to: 110.0, by: 0.41) {
    if let h = db.nearest(latitude: lat, longitude: lon), h.km > 35, h.km < 90 { near = (lat, lon); break } }
    if near != nil { break } }
if let near { check("偏远地区", near.0, near.1) { $0?.contains("附近") == true } }
check("佛山中心（不该算成广州）", 23.0215, 113.1214) { $0?.hasPrefix("佛山") == true }
check("东京站→东京", 35.6812, 139.7671) { $0?.hasPrefix("东京") == true }
check("埃菲尔铁塔→巴黎", 48.8584, 2.2945) { $0?.hasPrefix("巴黎") == true }
