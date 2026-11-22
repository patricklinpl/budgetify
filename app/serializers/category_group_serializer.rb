# Serializes a CategoryGroup (spec: CategoryGroup schema), optionally with
# its embedded categories (spec: CategoryGroupWithCategories).
class CategoryGroupSerializer
  def self.as_json(group, categories: nil, month: nil)
    data = {
      id: group.public_id,
      name: group.name,
      hidden: group.hidden,
      internal: group.internal,
      deleted: group.deleted
    }
    data[:categories] = categories.map { |category| CategorySerializer.as_json(category, month: month) } unless categories.nil?
    data
  end
end
