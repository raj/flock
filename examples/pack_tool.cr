# flock pack tool: bundle a directory of assets into a single .flkpack archive.
#
#   crystal run examples/pack_tool.cr -- <dir> <out.flkpack>
#
# Keys are the file paths relative to <dir> (forward slashes). At runtime:
#   assets.mount(Flock::Pack.open("out.flkpack"))
#   assets.load(Flock::Texture, "sprites/player.png")
require "../src/flock/pack"

if ARGV.size < 2
  STDERR.puts "usage: pack_tool <dir> <out.flkpack>"
  exit 1
end
dir, dest = ARGV[0], ARGV[1]

w = Flock::PackWriter.new
w.add_dir(dir)
size = w.write(dest)

puts "packed #{w.keys.size} assets → #{dest} (#{size} bytes)"
w.keys.sort.each { |k| puts "  #{k}" }
