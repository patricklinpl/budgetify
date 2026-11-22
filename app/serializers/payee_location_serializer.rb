# Serializes a PayeeLocation (spec: PayeeLocation schema). Latitude and
# longitude are strings per the spec.
class PayeeLocationSerializer
  def self.as_json(location)
    {
      id: location.public_id,
      payee_id: location.payee.public_id,
      latitude: location.latitude,
      longitude: location.longitude,
      deleted: location.deleted
    }
  end
end
