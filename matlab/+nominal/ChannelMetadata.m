classdef ChannelMetadata < nominal.Resource
    % CHANNELMETADATA  A channel's units, description, and data type.
    %
    %   This is the catalog side of a channel — deliberately distinct from
    %   nominal.Channel, which is the write address points are streamed to.
    %   Both describe the same series in Nominal, but they are keyed
    %   differently: metadata by (dataset, name) with no tags, streaming by
    %   stream and name with tags stamped on each point.
    %
    %       m = ds.channelMetadata("rpm");
    %       m.Unit
    %
    %       ds.setChannelMetadata("rpm", "double", Unit="1/min");
    %
    %   Metadata is scoped to a single dataset. Setting a unit on "rpm" in one
    %   dataset does not set it on "rpm" in another, even with matching names.
    %
    %   See also NOMINAL.DATASET, NOMINAL.CHANNEL

    properties (Dependent, SetAccess = private)
        Name string           % Channel name.
        Unit string           % UCUM unit symbol, or "" if unset.
        Description string    % Description, or "" if unset.
        DataType string       % "double", "string", "int", and so on.
        DatasourceRid string  % RID of the dataset this channel belongs to.
    end

    methods
        function obj = ChannelMetadata(handle)
            % Constructed by nominal.Dataset; not called directly.
            arguments
                handle (1,1) int32
            end
            obj.Handle = handle;
        end

        function v = get.Name(obj);          obj.assertLive(); v = string(nominalmex('meta_name', obj.Handle));           end
        function v = get.Unit(obj);          obj.assertLive(); v = string(nominalmex('meta_unit', obj.Handle));           end
        function v = get.Description(obj);   obj.assertLive(); v = string(nominalmex('meta_description', obj.Handle));    end
        function v = get.DataType(obj);      obj.assertLive(); v = string(nominalmex('meta_data_type', obj.Handle));      end
        function v = get.DatasourceRid(obj); obj.assertLive(); v = string(nominalmex('meta_datasource_rid', obj.Handle)); end
    end

    methods (Access = protected)
        function releaseHandle(obj)
            nominalmex('meta_free', obj.Handle);
        end
    end
end
