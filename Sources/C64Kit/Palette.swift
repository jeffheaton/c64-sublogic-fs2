/// The 16 VIC-II colors as 0xAARRGGBB, plus a luma-only variant for black-and-white monitors.
public enum C64Palette {
    /// "Colodore" palette (Philip Timmermann's VIC-II measurements).
    public static let color: [UInt32] = [
        0xFF00_0000, 0xFFFF_FFFF, 0xFF81_3338, 0xFF75_CEC8,
        0xFF8E_3C97, 0xFF56_AC4D, 0xFF2E_2C9B, 0xFFED_F171,
        0xFF8E_5029, 0xFF55_3800, 0xFFC4_6C71, 0xFF4A_4A4A,
        0xFF7B_7B7B, 0xFFA9_FF9F, 0xFF70_6DEB, 0xFFB2_B2B2,
    ]

    /// Gray levels a monochrome monitor shows for each color (VIC-II luma groups).
    public static let monochrome: [UInt32] = color.map { argb in
        let r = Double((argb >> 16) & 0xFF), g = Double((argb >> 8) & 0xFF), b = Double(argb & 0xFF)
        let y = UInt32((0.299 * r + 0.587 * g + 0.114 * b).rounded())
        return 0xFF00_0000 | (y << 16) | (y << 8) | y
    }
}
