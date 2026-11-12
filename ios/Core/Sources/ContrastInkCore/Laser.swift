/// The laser pointer: a glowing dot where Apple Pencil hovers or touches, and while touching, a glowing line that
/// fades away behind it. Never a mark: not kept with the slide, not undone, not erased.
public enum Laser {
    public static let color = "#FF2D2D"
    /// Each bit of the line stays bright this long after it was drawn (seconds)...
    public static let hold = 0.6
    /// ...then fades out over this long.
    public static let out = 0.6

    /// How bright a bit of the line drawn `age` seconds ago is: 1 = fully, 0 = gone (drop it).
    public static func opacity(age: Double) -> Double {
        if age <= hold { return 1 }
        let t = (age - hold) / out
        return t >= 1 ? 0 : 1 - t
    }

    /// The line's width (slide points) for the chosen pen width: easy to see from the back of a lecture hall.
    public static func width(_ penWidth: Double) -> Double { max(8, penWidth * 1.6) }
}
