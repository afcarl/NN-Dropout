classdef BlockNet < handle
    % This is a class for managing a simple multi-layer neural-net.
    %
    % This class is fully structured around the "block" form of dropout
    %
    
    properties
        % act_func is an ActFunc instance for computing feed-forward activation
        % levels in hidden layers and backpropagating gradients
        act_func
        % out_func is an ActFunc instance for computing feed-forward activation
        % levels at the output layer
        out_func
        % loss_func is a LossFunc instance for computing loss values/gradients
        loss_func
        % depth is the number of layers (including in/out) in this neural-net
        depth
        % layer_nsizes gives the number of nodes in each layer of this net
        %   note: these sizes do _not_ include the bias
        layer_nsizes
        % layer_bsizes gives the size of blocks in each layer of this net
        layer_bsizes
        % layer_bcounts gives the number of blocks in each layer
        layer_bcounts
        % layer_bmembs contains index sets for each block in each layer
        layer_bmembs
        % layer_weights is a cell array such that layer_weights{l} contains a
        % matrix in which entry (i,j) contains the weights between node i in
        % layer l and node j in layer l+1. The number of weight matrices in
        % layer_weights (i.e. its length) is self.depth - 1.
        %   note: due to biases each matrix in layer_weights has an extra row
        layer_weights
        % do_drop says whether or not we are using dropout (fixed rate to 0.5)
        do_drop
    end
    
    methods
        function [self] = BlockNet(act_func, out_func, loss_func)
            % Constructor for BlockNet class
            self.act_func = act_func;
            self.out_func = out_func;
            self.loss_func = loss_func;
            self.depth = [];
            self.layer_nsizes = [];
            self.layer_bsizes = [];
            self.layer_bcounts = [];
            self.layer_bmembs = [];
            self.layer_weights = [];
            self.do_drop = 0;
            return
        end
        
        function [ result ] = init_blocks(self, bsizes, bcounts, weight_scale)
            % Do a full init of the network, including block parameters and
            % edge weights.
            %
            self.set_blocks(bsizes, bcounts);
            self.init_weights(weight_scale);
            result = 1;
            return
        end
        
        function [ result ] = set_blocks(self, bsizes, bcounts)
            % Set the block sizes and counts for each layer in this net.
            % Currently, sizes other than 1 are not accepted for input layer.
            %
            self.depth = numel(bsizes);
            self.layer_nsizes = zeros(1,self.depth);
            self.layer_bsizes = zeros(1,self.depth);
            self.layer_bcounts = zeros(1,self.depth);
            self.layer_bmembs = cell(1,self.depth);
            for i=1:self.depth,
                self.layer_bsizes(i) = bsizes(i);
                self.layer_bcounts(i) = bcounts(i);
                self.layer_nsizes(i) = bsizes(i) * bcounts(i);
                % Compute sets of member indices for the blocks in this layer
                bmembs = zeros(bcounts(i), bsizes(i));
                for b=1:bcounts(i),
                    b_start = ((b - 1) * bsizes(i)) + 1;
                    b_end = b_start + (bsizes(i) - 1);
                    bmembs(b,:) = b_start:b_end;
                end
                self.layer_bmembs{i} = bmembs;
            end
            % Check to make sure the layer sizes implied by bsizes and bcounts
            % are concordant with previous layer sizes if they exist). If they
            % don't exist, then initialize the layer weights.
            if isempty(self.layer_weights)
                self.init_weights();
            else
                if (length(self.layer_weights) ~= (self.depth-1))
                    warning('set_blocks: contradiction with previous depth.');
                    self.init_weights();
                end
                for i=1:(self.depth-1),
                    lw = self.layer_weights{i};
                    if (((size(lw,1) - 1) ~=  self.layer_nsizes(i)) || ...
                            (size(lw,2) ~= self.layer_nsizes(i+1)))
                        warning('set_blocks: contradiction with layer sizes.');
                        self.init_weights();
                    end
                end
            end
            result = 1;
            return
        end
        
        function [ result ] = init_weights(self, weight_scale)
            % Initialize the connection weights for this neural net.
            %
            if ~exist('weight_scale','var')
                weight_scale = 0.1;
            end
            self.layer_weights = cell(1,self.depth-1);
            for i=1:(self.depth-1),
                % Add one to each outgoing layer weight count, for biases.
                weights = randn(self.layer_nsizes(i)+1,self.layer_nsizes(i+1));
                self.layer_weights{i} = weights .* weight_scale;
            end
            result = 0;
            return
        end
        
        function [ obs_acts ] = feedforward(self, X)
            % do a simple (i.e. no dropout) feed-forward computation for the
            % inputs in X
            obs_acts = X;
            for i=1:(self.depth-1),
                % Select activation function for the current layer
                if (i == self.depth-1)
                    func = self.out_func;
                else
                    func = self.act_func;
                end
                % Get weights connecting current layer to previous layer
                W = self.layer_weights{i};
                if ((self.do_drop == 1) && (i > 1))
                    % Halve the weights when net was trained with dropout rate
                    % near 0.5 for hidden nodes, to approximate sampling from
                    % the implied distribution over network architectures.
                    % Weights for first layer are not halved, as they modulate
                    % inputs from observed rather than hidden nodes.
                    W = W ./ 2;
                end
                % Compute activations at the current layer via feedforward
                obs_acts = func.feedforward(BlockNet.bias(obs_acts), W);
            end
            return
        end
        
        function [ result ] = backprop(self, X, Y, dr_obs)
            % Do a backprop computation with dropout for the data in X/Y.
            if ~exist('dr_obs','var')
                dr_obs = 0.0;
            end
            obs_count = size(X,1);
            drop_weights = self.layer_weights;
            % Effect random observation and node dropping by zeroing afferent
            % and efferent weights for randomly selected blocks in each layer,
            % with the "block size" at input layer fixed to 1.
            if (self.do_drop)
                for i=1:(self.depth-1),
                    if (i == 1)
                        if (dr_obs > 1e-5)
                            % Do dropout at input layer
                            post_weights = drop_weights{i};
                            mask = rand(size(post_weights,1),1) > dr_obs;
                            mask(end) = 1;
                            drop_weights{i} = bsxfun(@times,post_weights,mask);
                        end
                    else
                        % Do dropout at hidden node layers
                        pre_weights = drop_weights{i-1};
                        post_weights = drop_weights{i};
                        bcount = self.layer_bcounts(i);
                        bmembs = self.layer_bmembs{i};
                        drop_blocks = randsample(bcount, round(bcount/2));
                        drop_nodes = unique(bmembs(drop_blocks,:));
                        mask = ones(size(post_weights,1),1);
                        mask(drop_nodes) = 0;
                        % mask post_weights
                        post_weights = bsxfun(@times, post_weights, mask);
                        drop_weights{i} = post_weights;
                        % mask pre_weights
                        mask = mask(1:(end-1))';
                        drop_weights{i-1} = bsxfun(@times, pre_weights, mask);
                    end
                    
                end
            end
            % Compute per-layer activations for the full observation set
            layer_acts = cell(1,self.depth);
            layer_acts{1} = X;
            for i=2:self.depth,
                if (i == self.depth)
                    func = self.out_func;
                else
                    func = self.act_func;
                end
                W = drop_weights{i-1};
                A = layer_acts{i-1};
                layer_acts{i} = func.feedforward(BlockNet.bias(A), W);
            end
            % Compute gradients at all nodes, starting with loss values and
            % gradients for each observation at output layer
            node_grads = cell(1,self.depth);
            weight_grads = cell(1,self.depth-1);
            [L dL] = self.loss_func.evaluate(layer_acts{self.depth}, Y);
            for i=1:(self.depth-1),
                l_num = self.depth - i;
                if (l_num == (self.depth - 1))
                    func = self.out_func;
                    post_weights = 1;
                    post_grads = dL;
                else
                    func = self.act_func;
                    post_weights = drop_weights{l_num+1};
                    post_weights(end,:) = [];
                    post_grads = node_grads{l_num+1};
                end
                pre_acts = BlockNet.bias(layer_acts{l_num});
                pre_weights = drop_weights{l_num};
                cur_grads = func.backprop(...
                    post_grads, post_weights, pre_acts, pre_weights);
                weight_grads{l_num} = pre_acts' * (cur_grads ./ obs_count);
                node_grads{l_num} = cur_grads;
            end
            result = struct();
            result.layer_grads = weight_grads;
            return
        end
        
        function [ result ] =  complex_update(self, X, Y, params)
            % Do fully parameterized training for a BlockNet
            if ~exist('params','var')
                params = struct();
            end
            if ~isfield(params, 'epochs')
                params.epochs = 100;
            end
            if ~isfield(params, 'start_rate')
                params.start_rate = 1.0;
            end
            if ~isfield(params, 'decay_rate')
                params.decay_rate = 0.995;
            end
            if ~isfield(params, 'momentum')
                params.momentum = 0.25;
            end
            if ~isfield(params, 'weight_bound')
                params.weight_bound = 10;
            end
            if ~isfield(params, 'batch_size')
                params.batch_size = 100;
            end
            if ~isfield(params, 'dr_obs')
                params.dr_obs = 0.0;
            end
            if ~isfield(params, 'do_validate')
                params.do_validate = 0;
            end
            if (params.do_validate == 1)
                if (~isfield(params, 'X_v') || ~isfield(params, 'Y_v'))
                    error('Validation set required for doing validation.');
                end
            end
            params.momentum = min(1, max(0, params.momentum));
            obs_count = size(X,1);
            rate = params.start_rate;
            dW_pre = cell(1,self.depth-1);
            train_accs = zeros(1,params.epochs);
            train_loss = zeros(1,params.epochs);
            if (params.do_validate)
                test_accs = zeros(1,params.epochs);
                test_loss = zeros(1,params.epochs);
            end
            max_grad_norms = zeros(params.epochs, self.depth-1);
            all_idx = 1:obs_count;
            batch_size = params.batch_size;
            fprintf('Updating weights (%d epochs):\n', params.epochs);
            for e=1:params.epochs,
                idx = randsample(all_idx, batch_size, false);
                Xtr = X(idx,:);
                Ytr = Y(idx,:);
                for r=1:params.batch_rounds,
                    % Run backprop to compute gradients for this training batch
                    res = self.backprop(Xtr, Ytr, params.dr_obs);
                    for i=1:(self.depth-1),
                        % Update the weights at this layer using a momentum
                        % weighted mixture of the current gradients and the
                        % previous update.
                        l_grads = res.layer_grads{i};
                        l_grads_norms = sqrt(sum(l_grads.^2,1));
                        max_grad_norms(e, i) = max(l_grads_norms);
                        l_weights = self.layer_weights{i};
                        if (e == 1)
                            dW = rate * l_grads;
                        else
                            dW = (params.momentum * dW_pre{i}) + ...
                                ((1 - params.momentum) * (rate * l_grads));
                        end
                        dW_pre{i} = dW;
                        l_weights = l_weights - dW;
                        % Force the collection of weights incident on each node
                        % on the outgoing side of this layer's weights to have
                        % norm bounded by params.weight_bound.
                        l_norms = sqrt(sum(l_weights.^2,1));
                        l_scales = min(1, (params.weight_bound ./ l_norms));
                        self.layer_weights{i} = ...
                            bsxfun(@times, l_weights, l_scales);
                    end
                end
                % Decay the learning rate after performing update
                rate = rate * params.decay_rate;
                % Occasionally recompute and display the loss and accuracy
                if ((e == 1) || (mod(e, 200) == 0))
                    if (size(X,1) > 5000)
                        idx = randsample(size(X,1),5000);
                    else
                        idx = 1:size(X,1);
                    end
                    Y_s = Y(idx,:);
                    Yh_s = self.feedforward(X(idx,:));
                    [max_vals Y_s_idx] = max(Y_s,[],2);
                    [max_vals Yh_s_idx] = max(Yh_s,[],2);
                    L = self.loss_func.evaluate(Yh_s, Y_s);
                    acc = sum(Y_s_idx == Yh_s_idx) / numel(Y_s_idx);
                    if (params.do_validate)
                        Yh_v = self.feedforward(params.X_v);
                        [max_vals Y_v_idx] = max(params.Y_v,[],2);
                        [max_vals Yh_v_idx] = max(Yh_v,[],2);
                        L_v = self.loss_func.evaluate(Yh_v, params.Y_v);
                        acc_v = sum(Yh_v_idx == Y_v_idx) / numel(Y_v_idx);
                        fprintf('    %d: t=(%.4f, %.4f) v=(%.4f, %.4f)\n',...
                            e, mean(L(:)), acc, mean(L_v(:)), acc_v);
                    else
                        fprintf('    %d: %.4f, %.4f\n', e, mean(L(:)), acc);
                    end
                end
                train_loss(e) = mean(L(:));
                train_accs(e) = acc;
                if (params.do_validate)
                    test_loss(e) = mean(L_v(:));
                    test_accs(e) = acc_v;
                end
            end
            fprintf('\n');
            result = struct();
            result.Yh = self.feedforward(X);
            result.max_grad_norms = max_grad_norms;
            result.train_accs = train_accs;
            result.train_loss = train_loss;
            if (params.do_validate)
                result.test_accs = test_accs;
                result.test_loss = test_loss;
            end
            return
        end
        
    end
    
    methods (Static = true)
        function [ Xb ] = bias(X)
            % Add a column of constant bias to the observations in X
            Xb = [X ones(size(X,1),1)];
            return
        end
        
        function [ samples ] = weighted_sample( values, sample_count, weights )
            % Do weighted sampling of the vlaues in 'value' using a probability
            % distribution determined by 'weights', without replacement.
            samples = zeros(1, sample_count);
            free_values = values;
            free_weights = weights;
            for i=1:sample_count,
                s_idx = randsample(numel(free_weights), 1, true, free_weights);
                free_weights(s_idx) = 0;
                samples(i) = free_values(s_idx);
            end
            return
        end
            
    end 
    
end










%%%%%%%%%%%%%%
% EYE BUFFER %
%%%%%%%%%%%%%%
