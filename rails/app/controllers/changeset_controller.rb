class ChangesetController < ApplicationController
  def changesets
    @changesets = find_changesets_by_tile(params[:x].to_i, params[:y].to_i, params[:zoom].to_i, 20)

    if params[:nogeom] == 'true'
      render :template => 'changeset/changesets_nogeom', :layout => false
    else
      #render :template => 'changeset/changesets', :layout => false
      render :json => changesets_to_geojson(@changesets), :callback => params[:callback]
    end
  end

private
  def find_changesets_by_tile(x, y, zoom, limit)
    Changeset.find_by_sql("
      SELECT cs.*, ST_AsGeoJSON(ST_Union(cst.geom::geometry)) AS geojson
      FROM changeset_tiles cst
      INNER JOIN changesets cs ON (cs.id = cst.changeset_id)
      WHERE zoom = #{zoom} AND x = #{x} AND y = #{y}
      GROUP BY cs.id
      ORDER BY cs.created_at DESC
      LIMIT #{limit}
      ")
  end

  def changesets_to_geojson(changesets)
    geojson = { "type" => "FeatureCollection", "features" => []}

    changesets.each do |changeset|
      feature = { "type" => "Feature",
        "id" => "#{changeset.id}_#{rand(666666)}",
        "geometry" => JSON[changeset.geojson],
        "properties" => {
          "changeset_id" => changeset.id,
          "created_at" => changeset.created_at,
          "user_id" => changeset.user.id,
          "user_name" => changeset.user.name,
          "num_changes" => changeset.num_changes
        }
      }

      geojson['features'] << feature
    end

    geojson
  end
end
