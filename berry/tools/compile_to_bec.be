import string
import global

# Usage: berry compile_to_bec.be <source.be> <target.bec>
# (_argv[0] is this script's own name, the actual arguments follow from index 1)
#
# This desktop Berry VM doesn't know Tasmota's native modules (tasmota,
# wifi, mqtt, ...), since they're registered in ESP32-specific C++ code that
# isn't built here. The compiler therefore aborts with "'name' undeclared" on
# the first reference to such an identifier. We catch exactly that error,
# create "name" as a dummy global (purely so the compiler knows it - the
# value 0 is never executed, since we only compile, never run) and recompile,
# until every referenced name is known.
#
# Kept in its own function so src/dst/f/... stay local here instead of
# ending up as extra (unused) entries in the global name-table snapshot that
# .bec files record when saved.
def build_bec(src, dst)
  var f = nil
  for i : 0 .. 50
    try
      f = compile(src, "file")
      break
    except .. as e, msg
      if e != "syntax_error" || string.find(msg, "undeclared") == nil
        raise e, msg
      end
      var i1 = string.find(msg, "'")
      var i2 = i1 != nil ? string.find(msg, "'", i1 + 1) : nil
      if i1 == nil || i2 == nil
        raise e, msg
      end
      var name = msg[i1 + 1 .. i2 - 1]
      global.setmember(name, 0)
    end
  end
  if f == nil
    raise "compile_error", "globals could not be resolved for " + src
  end
  var fh = open(dst, "wb")
  fh.savecode(f)
  fh.close()
end

build_bec(_argv[1], _argv[2])
