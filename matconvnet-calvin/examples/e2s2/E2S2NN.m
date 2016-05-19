classdef E2S2NN < CalvinNN
    % E2S2NN End-to-end region based semantic segmentation training.
    %
    % Copyright by Holger Caesar, 2015
    
    methods
        function obj = E2S2NN(net, imdb, nnOpts)
            obj = obj@CalvinNN(net, imdb, nnOpts);
        end
        
        function convertNetwork(obj)
            % convertNetwork(obj)
            
            % Run default conversion method
            convertNetwork@CalvinNN(obj);
            
            fprintf('Converting Fast R-CNN network to End-to-end region based network (region-to-pixel layer, etc.)...\n');
            
            % Rename variables for use on superpixel level (not pixel-level)
            obj.net.renameVar('label', 'labelsSP');
            obj.net.renameVar('instanceWeights', 'instanceWeightsSP');
            
            % Insert a regiontopixel layer before the loss
            if obj.nnOpts.misc.regionToPixel.use
                regionToPixelOpts = obj.nnOpts.misc.regionToPixel;
                regionToPixelOpts = rmfield(regionToPixelOpts, 'use');
                regionToPixelOpts = struct2Varargin(regionToPixelOpts);
                regionToPixelBlock = dagnn.RegionToPixel(regionToPixelOpts{:});
                insertLayer(obj.net, 'fc8', 'softmaxloss', 'regiontopixel8', regionToPixelBlock, 'overlapListAll', {});
            end
            
            % Add batch normalization before ReLUs if specified (conv only,
            % not fc layers)
            if isfield(obj.nnOpts.misc, 'batchNorm') && obj.nnOpts.misc.batchNorm
                % Get relus that have no FC layer before them
                reluInds = find(arrayfun(@(x) isa(x.block, 'dagnn.ReLU'), obj.net.layers));
                order = obj.net.getLayerExecutionOrder();
                for i = 1 : numel(reluInds)
                    predIdx = order(find(order == reluInds(i)) - 1);
                    if strStartsWith(obj.net.layers(predIdx).name, 'fc')
                        reluInds(i) = nan;
                    end
                end
                reluInds = reluInds(~isnan(reluInds));
                
                for i = 1 : numel(reluInds)
                    % Relu
                    reluIdx = reluInds(i);
                    reluLayerName = obj.net.layers(reluIdx).name;
                    reluInputIdx = obj.net.layers(reluIdx).inputIndexes;
                    assert(numel(reluInputIdx) == 1);
                    
                    % Left layer
                    leftLayerIdx = find(arrayfun(@(x) ismember(reluInputIdx, x.outputIndexes), obj.net.layers));
                    assert(numel(leftLayerIdx) == 1);
                    leftLayerName = obj.net.layers(leftLayerIdx).name;
                    leftParamIdx = obj.net.layers(leftLayerIdx).paramIndexes(1);
                    numChannels = size(obj.net.params(leftParamIdx).value, 4); % equals size(var, 3) of the input variable
                    
                    % Insert new layer
                    layerBlock = dagnn.BatchNorm('numChannels', numChannels);
                    layerParamValues = layerBlock.initParams();
                    layerName = sprintf('bn_%s', reluLayerName);
                    layerParamNames = cell(1, numel(layerParamValues));
                    for i = 1 : numel(layerParamValues) %#ok<FXSET>
                        layerParamNames{i} = sprintf('%s_%d', layerName, i);
                    end
                    insertLayer(obj.net, leftLayerName, reluLayerName, layerName, layerBlock, {}, {}, layerParamNames);
                    
                    for i = 1 : numel(layerParamValues) %#ok<FXSET>
                        paramIdx = obj.net.getParamIndex(layerParamNames{i});
                        obj.net.params(paramIdx).value = layerParamValues{i};
                        obj.net.params(paramIdx).learningRate = 0.1; %TODO: are these good values?
                        obj.net.params(paramIdx).weightDecay = 0;
                    end
                end
            end
            
            % Weakly supervised learning options
            if isfield(obj.nnOpts.misc, 'weaklySupervised')
                weaklySupervised = obj.nnOpts.misc.weaklySupervised;
            else
                weaklySupervised.use = false;
            end
            
            % Map from superpixels to pixels
            if true
                fprintf('Adding mapping from superpixel to pixel level...\n');
                
                insertLayer(obj.net, 'regiontopixel8', 'softmaxloss', 'pixelmap', dagnn.SuperPixelToPixelMap, {'blobsSP', 'oriImSize'}, {}, {});
                pixelMapIdx = obj.net.getLayerIndex('pixelmap');
                obj.net.renameVar(obj.net.layers(pixelMapIdx).outputs{1}, 'prediction');
                
                % Add an optional accuracy layer
                accLayer = dagnn.SegmentationAccuracyFlexible('labelCount', obj.imdb.numClasses);
                obj.net.addLayer('accuracy', accLayer, {'prediction', 'labels'}, 'accuracy');
                
                % FS loss
                if ~weaklySupervised.use
                    lossIdx = obj.net.getLayerIndex('softmaxloss');
                    scoresVar = obj.net.layers(lossIdx).inputs{1};
                    layerFS = dagnn.SegmentationLossPixel();
                    replaceLayer(obj.net, 'softmaxloss', 'softmaxloss', layerFS, {scoresVar, 'labels', 'classWeights'}, {}, {}, true);
                end
            end
            
            if weaklySupervised.use
                % WS loss
                if isfield(weaklySupervised, 'labelPresence') && weaklySupervised.labelPresence.use,
                    assert(obj.nnOpts.misc.regionToPixel.use);
                    
                    % Change parameters for loss
                    % (for compatibility we don't change the name of the loss)
                    lossIdx = obj.net.getLayerIndex('softmaxloss');
                    scoresVar = obj.net.layers(lossIdx).inputs{1};
                    layerWS = dagnn.SegmentationLossImage('useAbsent', obj.nnOpts.misc.weaklySupervised.useAbsent);
                    replaceLayer(obj.net, 'softmaxloss', 'softmaxloss', layerWS, {scoresVar, 'labelsImage', 'classWeights', 'masksThingsCell'}, {}, {}, true);
                end
            end
            
            % Sort layers by their first occurrence
            sortLayers(obj.net);
        end
        
        function[stats] = testOnSet(obj, varargin)
            % [stats] = testOnSet(obj, varargin)
            
            % Initial settings
            p = inputParser;
            addParameter(p, 'subset', 'test');
            addParameter(p, 'doCache', true);
            addParameter(p, 'limitImageCount', Inf);
            parse(p, varargin{:});
            
            subset = p.Results.subset;
            doCache = p.Results.doCache;
            limitImageCount = p.Results.limitImageCount;
            
            % Set the datasetMode to be active
            if strcmp(subset, 'test'),
                temp = [];
            else
                temp = obj.imdb.data.test;
                obj.imdb.data.test = obj.imdb.data.(subset);
            end
            
            % Run test
            stats = obj.test('subset', subset, 'doCache', doCache, 'limitImageCount', limitImageCount);
            if ~strcmp(subset, 'test'),
                stats.loss = [obj.stats.(subset)(end).objective]';
            end;
            
            % Restore the original test set
            if ~isempty(temp)
                obj.imdb.data.test = temp;
            end
        end
        
        function extractFeatures(obj, featFolder)
            % extractFeatures(obj, featFolder)
            
            % Init
            imageList = unique([obj.imdb.data.train; obj.imdb.data.val; obj.imdb.data.test]);
            imageCount = numel(imageList);
            
            % Update imdb's test set
            tempTest = obj.imdb.data.test;
            obj.imdb.data.test = imageList;
            
            % Set network to testing mode
            outputVarIdx = obj.prepareNetForTest();
            
            for imageIdx = 1 : imageCount
                printProgress('Classifying images', imageIdx, imageCount, 10);
                
                % Get batch
                inputs = obj.imdb.getBatch(imageIdx, obj.net);
                
                % Run forward pass
                obj.net.eval(inputs);
                
                % Extract probs
                curProbs = obj.net.vars(outputVarIdx).value;
                curProbs = gather(reshape(curProbs, [size(curProbs, 3), size(curProbs, 4)]))';
                
                % Store
                imageName = imageList{imageIdx};
                featPath = fullfile(featFolder, [imageName, '.mat']);
                features = double(curProbs); %#ok<NASGU>
                save(featPath, 'features', '-v6');
            end
            
            % Reset test set
            obj.imdb.data.test = tempTest;
        end
        
        function[outputVarIdx] = prepareNetForTest(obj)
            % [outputVarIdx] = prepareNetForTest(obj)
            
            % Move to GPU
            if ~isempty(obj.nnOpts.gpus)
                obj.net.move('gpu');
            end
            
            % Enable test mode
            obj.imdb.setDatasetMode('test');
            obj.net.mode = 'test';
            
            % Reset segments to default
            obj.imdb.batchOpts.segments.colorTypeIdx = 1;
            obj.imdb.updateSegmentNames();
            
            % Remove accuracy layer
            accuracyIdx = obj.net.getLayerIndex('accuracy');
            if ~isnan(accuracyIdx)
                obj.net.removeLayer('accuracy');
            end
            
            % Replace softmaxloss by softmax
            lossIdx = find(cellfun(@(x) isa(x, 'dagnn.Loss'), {obj.net.layers.block}));
            assert(numel(lossIdx) == 1);
            lossName = obj.net.layers(lossIdx).name;
            lossType = obj.net.layers(lossIdx).block.loss;
            lossInputs = obj.net.layers(lossIdx).inputs;
            if strcmp(lossType, 'softmaxlog')
                obj.net.removeLayer(lossName);
                outputLayerName = 'softmax';
                obj.net.addLayer(outputLayerName, dagnn.SoftMax(), lossInputs{1}, 'scores', {});
                outputLayerIdx = obj.net.getLayerIndex(outputLayerName);
                outputVarIdx = obj.net.layers(outputLayerIdx).outputIndexes;
            elseif strcmp(lossType, 'log')
                % Only output the scores of the regiontopixel layer
                obj.net.removeLayer(lossName);
                outputVarIdx = obj.net.getVarIndex(obj.net.getOutputs{1});
            else
                error('Error: Unknown loss function!');
            end
            
            % Set output variable to be precious
            obj.net.vars(outputVarIdx).precious = true;
            
            assert(numel(outputVarIdx) == 1);
        end
        
        function[stats] = test(obj, varargin)
            % [stats] = test(obj, varargin)
            
            % Initial settings
            p = inputParser;
            addParameter(p, 'subset', 'test');
            addParameter(p, 'doCache', true);
            addParameter(p, 'plotFreq', 15);
            addParameter(p, 'printFreq', 30);
            addParameter(p, 'limitImageCount', Inf);
            parse(p, varargin{:});
            
            subset = p.Results.subset;
            doCache = p.Results.doCache;
            plotFreq = p.Results.plotFreq;
            printFreq = p.Results.printFreq;
            limitImageCount = p.Results.limitImageCount;
            
            % Check that settings are valid
            if ~isinf(limitImageCount)
                assert(~doCache);
            end
            
            epoch = numel(obj.stats.train);
            statsPath = fullfile(obj.nnOpts.expDir, sprintf('stats-%s-epoch%d.mat', subset, epoch));
            labelingDir = fullfile(obj.nnOpts.expDir, sprintf('labelings-%s-epoch-%d', subset, epoch));
            if exist(statsPath, 'file') && doCache
                % Get stats from disk
                statsStruct = load(statsPath, 'stats');
                stats = statsStruct.stats;
            else
                % Create output folder
                if ~exist(labelingDir, 'dir')
                    mkdir(labelingDir);
                end
                
                % Limit images if specified (for quicker evaluation)
                if ~isinf(limitImageCount)
                    sel = randperm(numel(obj.imdb.data.test), min(limitImageCount, numel(obj.imdb.data.test)));
                    obj.imdb.data.test = obj.imdb.data.test(sel);
                end
                
                % Init
                imageCount = numel(obj.imdb.data.test); % even if we test on train it must say "test" here
                confusion = zeros(obj.imdb.numClasses, obj.imdb.numClasses);
                evalTimer = tic;
                
                % Prepare colors for visualization
                labelNames = obj.imdb.dataset.getLabelNames();
                colorMapping = FCNNN.labelColors(obj.imdb.numClasses);
                colorMappingError = [0, 0, 0; ...    % background
                    1, 0, 0; ...    % too much
                    1, 1, 0; ...    % too few
                    0, 1, 0; ...    % rightClass
                    0, 0, 1];       % wrongClass
                
                % Set network to testing mode
                outputVarIdx = obj.prepareNetForTest();
                
                for imageIdx = 1 : imageCount                    
                    % Check whether GT labels are available for this image
                    imageName = obj.imdb.data.test{imageIdx};
                    labelMap = obj.imdb.dataset.getImLabelMap(imageName);
                    if all(labelMap(:) == 0)
                        continue;
                    end
                    
                    % Get batch
                    inputs = obj.imdb.getBatch(imageIdx, obj.net, obj.nnOpts);
                    
                    % Run forward pass
                    obj.net.eval(inputs);
                    
                    % Get pixel level predictions
                    scores = obj.net.vars(outputVarIdx).value;
                    [~, outputMap] = max(scores, [], 3);
                    outputMap = gather(outputMap);
                    
                    % Accumulate errors
                    ok = labelMap > 0;
                    confusion = confusion + accumarray([labelMap(ok), outputMap(ok)], 1, size(confusion));
                    
                    % Plot example images
                    if mod(imageIdx - 1, plotFreq) == 0 || imageIdx == imageCount
                        
                        % Create tiled image with image+gt+outputMap
                        if true
                            % Create tiling
                            tile = ImageTile();
                            
                            % Add GT image
                            image = obj.imdb.dataset.getImage(imageName) * 255;
                            tile.addImage(image / 255);
                            labelMapIm = ind2rgb(double(labelMap), colorMapping);
                            labelMapIm = imageInsertBlobLabels(labelMapIm, labelMap, labelNames);
                            tile.addImage(labelMapIm);
                            
                            % Add prediction image
                            outputMapNoBg = outputMap;
                            outputMapNoBg(labelMap == 0) = 0;
                            outputMapIm = ind2rgb(outputMapNoBg, colorMapping);
                            outputMapIm = imageInsertBlobLabels(outputMapIm, outputMapNoBg, labelNames);
                            tile.addImage(outputMapIm);
                            
                            % Highlight differences between GT and outputMap
                            errorMap = ones(size(labelMap));
                            
                            % For datasets without bg
                            rightClass = labelMap == outputMap & labelMap >= 1;
                            wrongClass = labelMap ~= outputMap & labelMap >= 1;
                            errorMap(rightClass) = 4;
                            errorMap(wrongClass) = 5;
                            errorIm = ind2rgb(double(errorMap), colorMappingError);
                            tile.addImage(errorIm);
                            
                            % Save segmentatioPredn
                            image = tile.getTiling('totalX', numel(tile.images), 'delimiterPixels', 1, 'backgroundBlack', false);
                            imPath = fullfile(labelingDir, [imageName, '.png']);
                            imwrite(image, imPath);
                        end
                    end
                    
                    % Print message
                    if mod(imageIdx - 1, printFreq) == 0 || imageIdx == imageCount
                        evalTime = toc(evalTimer);
                        fprintf('Processing image %d of %d (%.2f Hz)...\n', imageIdx, imageCount, imageIdx / evalTime);
                    end
                end
                
                % Final statistics, remove classes missing in test
                % Note: Printing statistics earlier does not make sense if we remove missing
                % classes
                [stats.miu, stats.pacc, stats.macc] = confMatToAccuracies(confusion);
                stats.confusion = confusion;
                fprintf('Results:\n');
                fprintf('pixelAcc: %5.2f, meanAcc: %5.2f, meanIU: %5.2f \n', ...
                    100 * stats.pacc, 100 * stats.macc, 100 * stats.miu);
                
                % Save results
                if doCache
                    if exist(statsPath, 'file'),
                        error('StatsPath already exists: %s', statsPath);
                    end
                    save(statsPath, '-struct', 'stats');
                end
            end
        end
    end
    
    methods (Static)
        function stats = extractStatsOldLoss(net, ~)
            % stats = extractStats(net)
            %
            % Extract all losses from the network.
            % Contrary to CalvinNN.extractStats(..) this measures loss on
            % an image (subbatch) level, not on a region level!
            
            lossInds = find(cellfun(@(x) isa(x, 'dagnn.Loss'), {net.layers.block}));
            stats = struct();
            for lossIdx = 1 : numel(lossInds)
                layerIdx = lossInds(lossIdx);
                objective = net.layers(layerIdx).block.average ...
                    * net.layers(layerIdx).block.numAveraged ...
                    / net.layers(layerIdx).block.numSubBatches;
                assert(~isnan(objective));
                stats.(net.layers(layerIdx).outputs{1}) = objective;
            end
        end
    end
end