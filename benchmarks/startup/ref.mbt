// startup reference, MoonBit. Native target, release build.
fn main {
  let args = @env.args()
  // args[0] is the executable, so the first passed argument is at 1.
  let n : Int64 = if args.length() > 1 {
    @strconv.parse_int64(args[1]) catch { _ => 0L }
  } else {
    0L
  }
  println("startup \{n * n + 1L}")
}
