# from:
#   http://www.oreillynet.com/ruby/blog/2005/12/adding_utility_to_core_classes_1.html
class Float
  def round_to(x)
    (self * 10**x).round.to_f / 10**x
  end
  def ceil_to(x)
    (self * 10**x).ceil.to_f / 10**x
  end
  def floor_to(x)
    (self * 10**x).floor.to_f / 10**x
  end
end